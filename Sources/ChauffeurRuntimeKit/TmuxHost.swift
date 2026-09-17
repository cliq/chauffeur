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
    private let environment: [String: String]
    public init(runtimeDirectory: URL, ctlPath: String, environment: [String: String]) throws {
        self.runtimeDirectory = runtimeDirectory; self.ctlPath = ctlPath
        self.executable = try Paths.executable("tmux", environment: environment)
        self.socketPath = runtimeDirectory.appendingPathComponent("tmux.sock").path
        self.environment = environment.filter { ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "TMPDIR"].contains($0.key) }
    }
    private func command(_ arguments: [String]) async throws -> CommandResult {
        try await ProcessRunner.run(executable, ["-S", socketPath, "-f", "/dev/null"] + arguments, environment: environment)
    }
    public func inventory() async throws -> [PaneIdentity] {
        // tmux replaces control characters such as tabs under the C locale.
        // All these generated identity/status fields have a printable delimiter.
        let result = try await command(["list-panes", "-a", "-F", "#{session_name}|#{pane_id}|#{pane_pid}|#{pane_dead}|#{pane_dead_status}"])
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
        let config = runtimeDirectory.appendingPathComponent("tmux.conf")
        // A separate socket/config keeps user tmux sessions and key bindings out
        // of Chauffeur. Direct argv launch never evaluates the task in a shell.
        try Data("set -g status off\nset -g prefix None\nset -g prefix2 None\nset -g mouse on\nset -g history-limit \(scrollback)\nset -g remain-on-exit on\nset -g exit-empty off\nset -g update-environment ''\nset -g default-terminal tmux-256color\n".utf8).write(to: config, options: .atomic)
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
            let creation = Task { try await ProcessRunner.run(executable, ["-S", socketPath, "-f", config.path, "start-server", ";", "set-option", "-g", "history-limit", String(scrollback), ";", "new-session", "-d", "-s", name, "-x", "100", "-y", "30", "-c", payload.directory, ctlPath, "internal-exec", payloadPath.path], environment: environment) }
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
        let pty = try PTYAttachment(executable: executable, arguments: ["-u", "-S", socketPath, "-T", "hyperlinks", "attach-session", "-t", sessionID.uuidString], directory: runtimeDirectory.path, environment: environment.merging(["TERM": "xterm-256color"], uniquingKeysWith: { _, new in new }), cols: cols, rows: rows)
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
        let metadata = try await command(["display-message", "-p", "-t", name, "#{pane_id}|#{pane_pid}|#{pane_width}|#{pane_height}|#{alternate_on}|#{history_size}"])
        let fields = metadata.output.trimmingCharacters(in: .newlines).split(separator: "|").map(String.init)
        guard metadata.status == 0, fields.count == 6, let pid = Int32(fields[1]), let columns = Int(fields[2]), let rows = Int(fields[3]), let historySize = Int(fields[5]) else { throw ChauffeurError("snapshot_unavailable", "Terminal history is unavailable") }
        var history = "", truncated = historySize > lines
        if historySize > 0 {
            let captured = try await capturePane(name, options: ["-S", "-\(min(lines, historySize))", "-E", "-1"])
            history = captured.output; truncated = truncated || captured.outputTruncated
        }
        if fields[4] == "1" {
            // In alternate-screen mode -a returns the saved normal screen;
            // the default capture still returns the active application's screen.
            let normal = try await capturePane(name, options: ["-a"])
            history += normal.output; truncated = truncated || normal.outputTruncated
        }
        let screen = try await capturePane(name, options: ["-S", "0", "-E", String(rows - 1)])
        guard let owner = try await inventory().first(where: { $0.sessionName == name }), owner.paneID == fields[0], owner.processID == pid else { throw ChauffeurError("snapshot_unavailable", "Terminal changed while its history was captured") }
        return TerminalSnapshot(sessionID: sessionID, processID: pid, terminalIdentity: fields[0], columns: columns, rows: rows, lineLimit: lines, history: history, screen: screen.output, truncated: truncated || screen.outputTruncated)
    }
    /// The command tmux reads from the pane's foreground process group, or
    /// `nil` when the pane is gone or its process has exited. A shell waiting at
    /// its own prompt reports the shell itself.
    public func foregroundCommand(sessionID: UUID) async throws -> String? {
        let result = try await command(["display-message", "-p", "-t", sessionID.uuidString, "#{pane_dead}|#{pane_current_command}"])
        guard result.status == 0 else { return nil }
        // A process name may itself contain the delimiter; it is the last field.
        let fields = result.output.trimmingCharacters(in: .newlines).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 2, fields[0] == "0", !fields[1].isEmpty else { return nil }
        return fields[1]
    }
    private func capturePane(_ name: String, options: [String]) async throws -> CommandResult {
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
        // tmux evaluates the owner and dead checks together, so a concurrent
        // explicit resume can never have its replacement pane retired here.
        let condition = "#{&&:#{pane_dead},#{&&:#{==:#{pane_id},\(snapshot.terminalIdentity)},#{==:#{pane_pid},\(snapshot.processID)}}}"
        _ = try await command(["if-shell", "-F", "-t", snapshot.sessionID.uuidString, condition, "kill-session -t \(snapshot.sessionID.uuidString)"])
    }
    public func interrupt(sessionID: UUID) async throws {
        let result = try await command(["send-keys", "-t", sessionID.uuidString, "C-c"])
        guard result.status == 0 else { throw ChauffeurError("interrupt_failed", "Session is no longer live") }
    }
    public func stop(sessionID: UUID, force: Bool) async throws {
        guard let pane = try await inventory().first(where: { $0.sessionName == sessionID.uuidString }) else { return }
        if force || pane.dead {
            let result = try await command(["kill-session", "-t", sessionID.uuidString])
            guard result.status == 0 else { throw ChauffeurError("stop_failed", "Could not stop terminal session") }
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
