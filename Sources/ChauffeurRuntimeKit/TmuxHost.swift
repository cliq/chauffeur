import Foundation
import Darwin
import CChauffeur
import ChauffeurCore

public struct PaneIdentity: Codable, Sendable {
    public var sessionName: String
    public var paneID: String
    public var processID: Int32
    public var dead: Bool
    public var exitStatus: Int32?
}

public actor TmuxHost {
    public let executable: String
    public let socketPath: String
    private let runtimeDirectory: URL
    private let ctlPath: String
    private let sessionOwner: SessionOwnerHost?
    private var sessionSockets: [UUID: String] = [:]
    private struct Attachment {
        let generation: AttachmentGeneration
        let pty: PTYAttachment
        let pump: AttachmentPump
        let sink: any TerminalOutputSink
    }
    private var attachments: [UUID: Attachment] = [:]
    /// Never reused, so a revoked client's late commands can be told apart
    /// from the client that replaced it.
    private var nextGeneration: AttachmentGeneration = 1
    private var spawning = Set<UUID>()
    /// Sessions whose native composer is being checked or populated by an
    /// orchestrated follow-up. Terminal clients must not race that operation.
    private var followUpSubmissions = Set<UUID>()
    /// Servers started by an older runtime keep `set-clipboard external`, which drops applications'
    /// OSC 52 writes; apply the current setting live once per host instead of restarting tmux.
    private var clipboardForwardingEnsured = Set<String>()
    private let environment: [String: String]
    public init(runtimeDirectory: URL, ctlPath: String, environment: [String: String], sessionsApp: URL? = nil) throws {
        self.runtimeDirectory = runtimeDirectory; self.ctlPath = ctlPath
        self.executable = try Paths.executable("tmux", environment: environment)
        self.socketPath = runtimeDirectory.appendingPathComponent("tmux.sock").path
        self.environment = environment.filter { ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR"].contains($0.key) }
        if let sessionsApp { sessionOwner = SessionOwnerHost(runtimeDirectory: runtimeDirectory, embeddedApp: sessionsApp, executable: self.executable, environment: self.environment) }
        else { sessionOwner = nil }
    }
    private func command(_ arguments: [String], socket: String) async throws -> CommandResult {
        try await ProcessRunner.run(executable, ["-N", "-S", socket, "-f", "/dev/null"] + arguments, environment: environment)
    }
    private func findSocket(for sessionID: UUID) async throws -> String? {
        if let socket = sessionSockets[sessionID] { return socket }
        _ = try await inventory()
        return sessionSockets[sessionID]
    }
    private func socket(for sessionID: UUID) async throws -> String {
        guard let socket = try await findSocket(for: sessionID) else { throw ChauffeurError("terminal_missing", "Session is no longer live") }
        return socket
    }
    public func inventory() async throws -> [PaneIdentity] {
        let sockets = [socketPath] + (try SessionOwnerHost.manifests(in: runtimeDirectory)).map { $0.1.socketPath }
        var panes: [PaneIdentity] = []
        var routes: [UUID: String] = [:]
        for socket in sockets {
            for pane in try await inventory(socket: socket) {
                if let id = UUID(uuidString: pane.sessionName) {
                    guard routes[id] == nil else { throw ChauffeurError("terminal_inventory", "Session exists on multiple terminal servers") }
                    routes[id] = socket
                }
                panes.append(pane)
            }
        }
        // Do not lose a concurrent spawn's route while inventory is suspended.
        for (id, socket) in sessionSockets where spawning.contains(id) { routes[id] = socket }
        sessionSockets = routes
        return panes
    }
    private func inventory(socket: String) async throws -> [PaneIdentity] {
        // tmux replaces control characters such as tabs under the C locale.
        // All these generated identity/status fields have a printable delimiter.
        let result = try await command(["list-panes", "-a", "-F", "#{session_name}|#{pane_id}|#{pane_pid}|#{pane_dead}|#{pane_dead_status}"], socket: socket)
        if result.status != 0 {
            if result.error.contains("no server running") || result.error.contains("no sessions") || result.error.contains("no current target") || result.error.contains("No such file") || result.error.contains("Connection refused") { return [] }
            throw ChauffeurError("terminal_inventory", "Cannot inspect terminal service")
        }
        return try result.output.split(separator: "\n").map { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let pid = Int32(fields[2]), ["0", "1"].contains(fields[3]), fields[4].isEmpty || Int32(fields[4]) != nil else {
                throw ChauffeurError("terminal_inventory", "Terminal service returned an unreadable inventory")
            }
            return PaneIdentity(sessionName: fields[0], paneID: fields[1], processID: pid, dead: fields[3] == "1", exitStatus: Int32(fields[4]))
        }
    }
    public func spawn(session: Session, payload: ExecPayload, scrollback: Int) async throws -> PaneIdentity {
        try Task.checkCancellation()
        guard spawning.insert(session.id).inserted else { throw ChauffeurError("launch_pending", "Terminal creation is already in progress") }
        defer { spawning.remove(session.id) }
        let name = session.id.uuidString
        guard !(try await inventory()).contains(where: { $0.sessionName == name }) else { throw ChauffeurError("already_running", "Session already has a terminal. Reattach instead") }
        let socketPath = try await sessionOwner?.socket() ?? self.socketPath
        sessionSockets[session.id] = socketPath
        let config = runtimeDirectory.appendingPathComponent("tmux.conf")
        // A separate socket/config keeps user tmux sessions and key bindings out
        // of Chauffeur. Direct argv launch never evaluates the task in a shell.
        try SessionOwnerManifest.configuration(scrollback: scrollback).write(to: config, options: .atomic)
        let payloadPath = runtimeDirectory.appendingPathComponent("launch-\(session.id).json")
        guard FileManager.default.createFile(atPath: payloadPath.path, contents: try JSONCoding.encode(payload), attributes: [.posixPermissions: 0o600]) else { throw ChauffeurError("launch_file", "Cannot create private launch handoff") }
        defer { try? FileManager.default.removeItem(at: payloadPath) }
        // history-limit is read when a pane is created. Set it before new-session
        // even when the server already exists and does not reread its config.
        try Task.checkCancellation()
        do {
            // Do not cancel the tmux client halfway through submitting creation:
            // the server could still have its command queued. Await its reply,
            // then honour cancellation and remove the terminal before returning.
            let serverFlags = sessionOwner == nil ? [] : ["-N"]
            let creation = Task { try await ProcessRunner.run(executable, serverFlags + ["-S", socketPath, "-f", config.path, "start-server", ";", "set-option", "-g", "history-limit", String(scrollback), ";", "new-session", "-d", "-s", name, "-x", "100", "-y", "30", "-c", payload.directory, ctlPath, "internal-exec", payloadPath.path], environment: environment) }
            let result = try await creation.value
            try Task.checkCancellation()
            guard result.status == 0 else { throw ChauffeurError("terminal_launch", "tmux could not start the session", path: payload.directory) }
            let handoffDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while FileManager.default.fileExists(atPath: payloadPath.path) && ContinuousClock.now < handoffDeadline { try await Task.sleep(for: .milliseconds(20)) }
            guard !FileManager.default.fileExists(atPath: payloadPath.path) else { throw ChauffeurError("launch_handoff_timeout", "Terminal helper did not consume its launch configuration") }
            guard let pane = try await inventory().first(where: { $0.sessionName == name }) else { throw ChauffeurError("terminal_launch", "Launched terminal could not be found") }
            try Task.checkCancellation()
            return pane
        } catch {
            // Cleanup must run even when the creating task was cancelled. Keep
            // the reservation until this finishes so it cannot target a resume.
            try await Task { try await self.stop(sessionID: session.id, force: true) }.value
            throw error
        }
    }
    /// Attaches `sink` to a session's terminal and returns the generation that
    /// authorizes its input and resize commands. A session has one controlling
    /// client at a time: with `takeControl` the current one is revoked and told
    /// it lost control; without it the call fails with `terminal_busy`.
    ///
    /// Everything up to storing the new attachment runs without suspension, so
    /// a stale client's concurrent input cannot slip in between the revocation
    /// and the hand-over.
    public func attach(sessionID: UUID, sink: any TerminalOutputSink, cols: Int, rows: Int, takeControl: Bool) async throws -> AttachmentGeneration {
        let socketPath = try await socket(for: sessionID)
        await ensureClipboardForwarding(socket: socketPath)
        let generation = nextGeneration; nextGeneration += 1
        if let previous = attachments[sessionID] {
            guard takeControl else { throw ChauffeurError("terminal_busy", "This terminal is controlled by another client. Take control to use it here") }
            attachments.removeValue(forKey: sessionID)
            previous.pump.revoke(); previous.pty.close()
            let lostSink = previous.sink
            Task.detached { await lostSink.close(reason: .controlLost, message: "Another client took control of this terminal") }
        }
        // SwiftTerm supports OSC 8 links, but tmux's generic xterm-256color
        // features do not advertise them. Set this on every attachment so links
        // survive redraws and reconnects to already-running tmux servers too.
        // SwiftTerm always decodes UTF-8. launchd may supply no locale; without
        // -u tmux replaces Unicode with underscores before it reaches the UI.
        let pty = try PTYAttachment(executable: executable, arguments: ["-u", "-S", socketPath, "-T", "hyperlinks,clipboard", "attach-session", "-t", sessionID.uuidString], directory: runtimeDirectory.path, environment: environment.merging(["TERM": "xterm-256color"], uniquingKeysWith: { _, new in new }), cols: cols, rows: rows)
        let pump = AttachmentPump(generation: generation, sink: sink) { [weak self] ended in
            guard let self else { return }
            Task { await self.attachmentEnded(sessionID: sessionID, generation: ended) }
        }
        attachments[sessionID] = Attachment(generation: generation, pty: pty, pump: pump, sink: sink)
        pty.startOutput(into: pump)
        pump.start()
        return generation
    }
    public func input(sessionID: UUID, generation: AttachmentGeneration, bytes: Data) throws {
        guard !followUpSubmissions.contains(sessionID) else {
            throw ChauffeurError("follow_up_submission_pending", "A follow-up is being submitted to this terminal")
        }
        try current(sessionID, generation).pty.input(bytes)
    }
    public func resize(sessionID: UUID, generation: AttachmentGeneration, cols: Int, rows: Int) throws {
        try current(sessionID, generation).pty.resize(cols: cols, rows: rows)
    }
    /// Silently ignores a stale generation: a revoked client's teardown must
    /// never detach the client that replaced it.
    public func detach(sessionID: UUID, generation: AttachmentGeneration) {
        guard let attachment = attachments[sessionID], attachment.generation == generation else { return }
        attachments.removeValue(forKey: sessionID)
        attachment.pump.revoke(); attachment.pty.close()
        let sink = attachment.sink
        Task.detached { await sink.close(reason: .clientDetached, message: nil) }
    }
    /// The generation currently controlling a session's terminal, if any.
    public func currentGeneration(sessionID: UUID) -> AttachmentGeneration? { attachments[sessionID]?.generation }
    func isFollowUpSubmissionPending(sessionID: UUID) -> Bool { followUpSubmissions.contains(sessionID) }

    /// Verifies that the installed provider and its live terminal are at a
    /// known, empty native composer. Provider completion state is necessary but
    /// deliberately insufficient: dialogs, user drafts and a still-rendering
    /// turn are rejected from the current pane contents.
    public func validateFollowUp(session: Session) async throws {
        guard !followUpSubmissions.contains(session.id) else {
            throw ChauffeurError("follow_up_submission_pending", "A follow-up is already being submitted to this terminal")
        }
        try await validateFollowUpReadiness(session: session)
    }

    /// Submits a prompt to the existing interactive provider conversation.
    /// Readiness is checked again while terminal input is reserved, so callers
    /// may safely persist their turn before invoking this method without relying
    /// on an earlier, stale validation.
    public static func validateFollowUpPrompt(_ prompt: String) throws {
        try Validation.require(!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Follow-up prompt cannot be empty")
        try Validation.require(!prompt.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0.value != 0x0A && $0.value != 0x09
        }), "Follow-up prompt contains terminal control characters")
        try Validation.require(prompt.utf8.count <= 64 * 1024, "Follow-up prompt is too large")
    }

    public func submitFollowUp(session: Session, prompt: String) async throws {
        try Self.validateFollowUpPrompt(prompt)
        guard followUpSubmissions.insert(session.id).inserted else {
            throw ChauffeurError("follow_up_submission_pending", "A follow-up is already being submitted to this terminal")
        }
        defer { followUpSubmissions.remove(session.id) }

        try await validateFollowUpReadiness(session: session)
        let socketPath = try await socket(for: session.id)
        let bufferName = "chauffeur-follow-up-\(UUID().uuidString)"
        do {
            let buffered = try await command(["set-buffer", "-b", bufferName, "--", prompt], socket: socketPath)
            guard buffered.status == 0 else { throw ChauffeurError("follow_up_delivery_uncertain", "Follow-up delivery could not be confirmed") }
            // -p asks tmux to use the provider's enabled bracketed-paste mode,
            // so embedded newlines and tabs remain one editable prompt.
            let pasted = try await command(["paste-buffer", "-p", "-d", "-b", bufferName, "-t", session.id.uuidString], socket: socketPath)
            guard pasted.status == 0 else { throw ChauffeurError("follow_up_delivery_uncertain", "Follow-up delivery could not be confirmed") }
            // Both supported TUIs distinguish a pasted burst from Return on their
            // event loop. Let them finish accepting the literal text before submit.
            try await Task.sleep(for: .milliseconds(600))
            let submit = try await command(["send-keys", "-t", session.id.uuidString, "Enter"], socket: socketPath)
            guard submit.status == 0 else { throw ChauffeurError("follow_up_delivery_uncertain", "Follow-up delivery could not be confirmed") }
        } catch {
            _ = try? await command(["delete-buffer", "-b", bufferName], socket: socketPath)
            // Once the first tmux client is started, a timeout or cancellation
            // cannot prove whether some or all input reached the native TUI.
            throw ChauffeurError("follow_up_delivery_uncertain", "Follow-up delivery could not be confirmed")
        }
    }

    /// Provider identity is version-independent. Every submission still verifies
    /// live pane ownership, turn state, cursor position, and the blank composer.
    public static func supportsFollowUp(kind: CLIKind, version: String) -> Bool {
        CLIAdapter.identifiesProvider(kind: kind, version: version)
    }

    private func validateFollowUpReadiness(session: Session) async throws {
        let kind = session.launch.preset.kind
        guard Self.supportsFollowUp(kind: kind, version: session.launch.executableVersion) else {
            throw ChauffeurError("follow_up_unavailable", "The executable is not recognized as a supported agent provider")
        }
        switch session.state {
        case .turnFinished: break
        case .starting, .running:
            throw ChauffeurError("follow_up_busy", "The provider is still running a turn")
        case .needsAttention:
            throw ChauffeurError("follow_up_needs_attention", "The provider is waiting for input in a dialog")
        case .activityUnknown:
            throw ChauffeurError("follow_up_unavailable", "The provider's input readiness is unknown")
        case .exited, .failed, .interrupted:
            throw ChauffeurError("follow_up_unavailable", "The provider is no longer available for follow-up")
        }

        guard let expectedPane = session.terminalIdentity, let expectedPID = session.processID else {
            throw ChauffeurError("follow_up_unavailable", "The provider terminal identity is unavailable")
        }
        let socketPath = try await socket(for: session.id)
        let metadata = try await command(["display-message", "-p", "-t", session.id.uuidString, "#{pane_id}|#{pane_pid}|#{pane_dead}|#{cursor_y}|#{pane_height}"], socket: socketPath)
        let fields = metadata.output.trimmingCharacters(in: .newlines).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard metadata.status == 0, fields.count == 5, fields[0] == expectedPane,
              Int32(fields[1]) == expectedPID, fields[2] == "0",
              let cursorY = Int(fields[3]), let height = Int(fields[4]),
              cursorY >= 0, cursorY < height else {
            throw ChauffeurError("follow_up_unavailable", "The provider terminal identity or cursor state could not be verified")
        }
        let captured = try await ProcessRunner.run(executable, ["-S", socketPath, "capture-pane", "-p", "-t", session.id.uuidString], environment: environment, timeout: 3, outputLimit: 256 * 1024, keepOutputTail: true)
        guard captured.status == 0, !captured.outputTruncated else {
            throw ChauffeurError("follow_up_unavailable", "The provider's input readiness could not be inspected")
        }
        let lines = captured.output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.indices.contains(cursorY),
              let owner = try await inventory().first(where: { $0.sessionName == session.id.uuidString }),
              owner.paneID == expectedPane, owner.processID == expectedPID, !owner.dead else {
            throw ChauffeurError("follow_up_unavailable", "The provider terminal changed while input readiness was inspected")
        }
        let composer = Self.composerReadiness(kind: kind, activeLine: lines[cursorY])
        switch composer {
        case .ready: return
        case .inputPending:
            throw ChauffeurError("follow_up_input_pending", "The terminal already contains user input or an open dialog")
        case .unrecognized:
            throw ChauffeurError("follow_up_unavailable", "The provider is not at a recognized empty input prompt")
        }
    }

    enum ComposerReadiness: Equatable { case ready, inputPending, unrecognized }
    static func composerReadiness(kind: CLIKind, activeLine: String) -> ComposerReadiness {
        let line = activeLine.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .codex:
            if line == "› Ask Codex to do anything" { return .ready }
            if line == "›" || line.hasPrefix("› ") { return .inputPending }
        case .claude:
            if line.first == "❯" {
                let content = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if content.isEmpty { return .ready }
                return .inputPending
            }
        case .shell: break
        }
        return .unrecognized
    }
    private func ensureClipboardForwarding(socket: String) async {
        guard !clipboardForwardingEnsured.contains(socket) else { return }
        do {
            let result = try await ProcessRunner.run(executable, ["-N", "-S", socket, "set-option", "-g", "set-clipboard", "on"], environment: environment, timeout: 3)
            if result.status == 0 { clipboardForwardingEnsured.insert(socket) }
        } catch {
            // No server yet, or it is unreachable; the next attach tries again.
        }
    }
    private func current(_ sessionID: UUID, _ generation: AttachmentGeneration) throws -> Attachment {
        guard let attachment = attachments[sessionID] else { throw ChauffeurError("attachment_lost", "Terminal is not attached") }
        guard attachment.generation == generation else { throw ChauffeurError("attachment_revoked", "Another client took control of this terminal") }
        return attachment
    }
    /// The pump gave up on its own (slow consumer, transport failure or EOF);
    /// drop the attachment when it is still the current one and stop its client.
    private func attachmentEnded(sessionID: UUID, generation: AttachmentGeneration) {
        guard let attachment = attachments[sessionID], attachment.generation == generation else { return }
        attachments.removeValue(forKey: sessionID)
        attachment.pty.close()
    }
    public func capture(sessionID: UUID, lines: Int) async throws -> TerminalSnapshot {
        let name = sessionID.uuidString
        let socketPath = try await socket(for: sessionID)
        let metadata = try await command(["display-message", "-p", "-t", name, "#{pane_id}|#{pane_pid}|#{pane_width}|#{pane_height}|#{alternate_on}|#{history_size}"], socket: socketPath)
        let fields = metadata.output.trimmingCharacters(in: .newlines).split(separator: "|").map(String.init)
        guard metadata.status == 0, fields.count == 6, let pid = Int32(fields[1]), let columns = Int(fields[2]), let rows = Int(fields[3]), let historySize = Int(fields[5]) else { throw ChauffeurError("snapshot_unavailable", "Terminal history is unavailable") }
        var history = "", truncated = historySize > lines
        if historySize > 0 {
            let captured = try await capturePane(name, socket: socketPath, options: ["-S", "-\(min(lines, historySize))", "-E", "-1"])
            history = captured.output; truncated = truncated || captured.outputTruncated
        }
        if fields[4] == "1" {
            // In alternate-screen mode -a returns the saved normal screen;
            // the default capture still returns the active application's screen.
            let normal = try await capturePane(name, socket: socketPath, options: ["-a"])
            history += normal.output; truncated = truncated || normal.outputTruncated
        }
        let screen = try await capturePane(name, socket: socketPath, options: ["-S", "0", "-E", String(rows - 1)])
        guard let owner = try await inventory().first(where: { $0.sessionName == name }), owner.paneID == fields[0], owner.processID == pid else { throw ChauffeurError("snapshot_unavailable", "Terminal changed while its history was captured") }
        return TerminalSnapshot(sessionID: sessionID, processID: pid, terminalIdentity: fields[0], columns: columns, rows: rows, lineLimit: lines, history: history, screen: screen.output, truncated: truncated || screen.outputTruncated)
    }
    /// The command tmux reads from the pane's foreground process group, or
    /// `nil` when the pane is gone or its process has exited. A shell waiting at
    /// its own prompt reports the shell itself.
    public func foregroundCommand(sessionID: UUID) async throws -> String? {
        guard let socket = try await findSocket(for: sessionID) else { return nil }
        let result = try await command(["display-message", "-p", "-t", sessionID.uuidString, "#{pane_dead}|#{pane_current_command}"], socket: socket)
        guard result.status == 0 else { return nil }
        // A process name may itself contain the delimiter; it is the last field.
        let fields = result.output.trimmingCharacters(in: .newlines).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2, fields[0] == "0", !fields[1].isEmpty else { return nil }
        return fields[1]
    }
    private func capturePane(_ name: String, socket socketPath: String, options: [String]) async throws -> CommandResult {
        var result = try await ProcessRunner.run(executable, ["-S", socketPath, "capture-pane", "-p", "-e", "-t", name] + options, environment: environment, timeout: 3, outputLimit: TerminalSnapshot.maximumFileBytes, keepOutputTail: true)
        guard result.status == 0 else { throw ChauffeurError("snapshot_unavailable", "Terminal history is unavailable") }
        if result.outputTruncated {
            // A bounded byte tail may start inside UTF-8 or an escape sequence.
            result.output = result.output.firstIndex(of: "\n").map { String(result.output[result.output.index(after: $0)...]) } ?? ""
        }
        return result
    }
    public func retireDead(_ snapshot: TerminalSnapshot) async throws {
        try snapshot.validate()
        guard let socket = try await findSocket(for: snapshot.sessionID) else { return }
        // tmux evaluates the owner and dead checks together, so a concurrent
        // explicit resume can never have its replacement pane retired here.
        let condition = "#{&&:#{pane_dead},#{&&:#{==:#{pane_id},\(snapshot.terminalIdentity)},#{==:#{pane_pid},\(snapshot.processID)}}}"
        _ = try await command(["if-shell", "-F", "-t", snapshot.sessionID.uuidString, condition, "kill-session -t \(snapshot.sessionID.uuidString)"], socket: socket)
    }
    public func interrupt(sessionID: UUID) async throws {
        guard !followUpSubmissions.contains(sessionID) else {
            throw ChauffeurError("follow_up_submission_pending", "A follow-up is being submitted to this terminal")
        }
        let result = try await command(["send-keys", "-t", sessionID.uuidString, "C-c"], socket: socket(for: sessionID))
        guard result.status == 0 else { throw ChauffeurError("interrupt_failed", "Session is no longer live") }
    }
    public func stop(sessionID: UUID, force: Bool) async throws {
        guard !followUpSubmissions.contains(sessionID) else {
            throw ChauffeurError("follow_up_submission_pending", "A follow-up is being submitted to this terminal")
        }
        guard let pane = try await inventory().first(where: { $0.sessionName == sessionID.uuidString }) else { return }
        if force || pane.dead {
            do {
                let result = try await command(["kill-session", "-t", sessionID.uuidString], socket: socket(for: sessionID))
                guard result.status == 0 else { throw ChauffeurError("stop_failed", "Could not stop terminal session") }
            } catch {
                try Task.checkCancellation()
                // Exit, dead-pane retirement, and explicit close can overlap
                // across the awaits above. A failed command is harmless only
                // when a fresh inventory verifies the session is already gone.
                if try await inventory().contains(where: { $0.sessionName == sessionID.uuidString }) {
                    throw error
                }
            }
        } else {
            // Positive tmux ownership check above. Each pane is a PTY session
            // leader; signal this execution's process group only.
            guard kill(-pane.processID, SIGTERM) == 0 || errno == ESRCH else { throw ChauffeurError("stop_failed", "Graceful stop failed; force stop is available") }
        }
    }
}

private final class PTYAttachment: @unchecked Sendable {
    private let descriptor: Int32
    private let pid: Int32
    private let lock = NSLock()
    private var stopped = false
    init(executable: String, arguments: [String], directory: String, environment: [String: String], cols: Int, rows: Int) throws {
        try Self.validateSize(cols, rows)
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var master: Int32 = -1
        pid = chauffeur_spawn_pty(executable, &argv, &envp, directory, &master, UInt16(cols), UInt16(rows))
        guard pid > 0 else { throw ChauffeurError("pty_failed", "Could not allocate terminal attachment") }
        descriptor = master
    }
    deinit { Darwin.close(descriptor) }
    /// Reads the tmux client's output on a blocking thread into `pump`. The
    /// thread only ever cleans up this attachment's own process.
    func startOutput(into pump: AttachmentPump) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { close(); var status: Int32 = 0; waitpid(pid, &status, 0) }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { pump.finish(); return }
                pump.enqueue(Data(buffer[..<count]))
            }
        }
    }
    func input(_ data: Data) throws {
        try Validation.require(data.count <= 1024 * 1024, "Terminal input is too large")
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw ChauffeurError("attachment_closed", "Terminal view detached") }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ChauffeurError("input_failed", "Terminal input failed") }
                offset += count
            }
        }
    }
    func resize(cols: Int, rows: Int) throws { try Self.validateSize(cols, rows); guard chauffeur_resize(descriptor, UInt16(cols), UInt16(rows)) == 0 else { throw ChauffeurError("resize_failed", "Terminal resize failed") } }
    func close() {
        lock.lock(); defer { lock.unlock() }
        if !stopped { stopped = true; kill(pid, SIGTERM) }
    }
    private static func validateSize(_ cols: Int, _ rows: Int) throws { try Validation.require((2...500).contains(cols) && (2...300).contains(rows), "Terminal dimensions must be 2–500 columns and 2–300 rows") }
}
