import Foundation
import Darwin
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct LaunchCancellationTests {
    @Test func terminalAttachmentPreservesUnicodeWithoutLocaleVariables() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let expected = "UNICODE café 界 ❯ ✓ END"
        try Data(expected.utf8).write(to: fixture.path("unicode-output"))
        let session = try await fixture.runtime.launch(fixture.request)
        try await fixture.wait {
            try await fixture.runtime.terminals.capture(sessionID: session.id, lines: 100).screen.contains(expected)
        }
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let writer = SocketConnection(descriptor: descriptors[0]), reader = SocketConnection(descriptor: descriptors[1])
        defer { writer.close(); reader.close() }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        try #require(setsockopt(reader.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0)
        let owner = UUID()
        try await fixture.runtime.terminals.attach(sessionID: session.id, owner: owner, connection: writer, cols: 100, rows: 30)
        var output = Data()
        // The fixture's END marker also arrives in ASCII-only mode. Wait for
        // that complete redraw before asserting the actual non-ASCII bytes.
        while !String(decoding: output, as: UTF8.self).contains("END") {
            let packet = try await reader.receiveAsync(TerminalPacket.self)
            if let bytes = packet.bytes { output.append(bytes) }
        }
        #expect(String(decoding: output, as: UTF8.self).contains(expected))
        await fixture.runtime.terminals.detach(sessionID: session.id, owner: owner)
        _ = try await fixture.stop()
    }

    @Test func terminalActivityDistinguishesAnIdleShellFromRunningWork() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let request = LaunchRequest.shell(projectID: fixture.request.projectID, groupID: fixture.request.groupID, folderID: fixture.request.folderID, title: "Shell", worktreeID: nil)
        let shell = try await fixture.runtime.launch(request)
        try await fixture.wait { try await fixture.activity(shell.id).idle }
        #expect(try await fixture.activity(shell.id).command == "zsh")
        try fixture.sendKeys(sessionID: shell.id, "sleep 30")
        try await fixture.wait { try await fixture.activity(shell.id).command == "sleep" }
        #expect(try await !fixture.activity(shell.id).idle)
        // An agent CLI is its own pane's foreground process and is never idle.
        let agent = try await fixture.runtime.launch(fixture.request)
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("started").path) }
        #expect(try await !fixture.activity(agent.id).idle)
    }

    @Test(arguments: [["--sandbox", "read-only"], ["-s", "read-only"], ["--sandbox=read-only"], ["-s=read-only"]])
    func codexReadOnlyAdditionalFoldersFailBeforeInspectingOrStartingTheCLI(arguments: [String]) async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let preset = try #require(await fixture.runtime.store.current().presets.first)
        var changed = preset.value; changed.kind = .codex; changed.arguments = arguments
        try await fixture.runtime.store.save(changed, expectedVersion: preset.version)
        let additional = fixture.path("additional")
        try FileManager.default.createDirectory(at: additional, withIntermediateDirectories: true)
        let stored = try #require(await fixture.runtime.store.current().projects.first)
        var project = stored.value; project.addFolder(ProjectFolder(path: additional.path))
        try await fixture.runtime.store.save(project, expectedVersion: stored.version)
        var request = fixture.request; request.additionalFolderIDs = [project.folders.last!.id]
        let result = await Task { [request] in try await fixture.runtime.launch(request) }.result
        #expect(result.failureCode == "unsupported_directories")
        #expect(!FileManager.default.fileExists(atPath: fixture.path("version-entered").path))
        #expect(try await fixture.runtime.terminals.inventory().isEmpty)
        #expect(try await fixture.session().state == .failed)
        // Removing the additional folder keeps read-only available.
        request.additionalFolderIDs = []; request.retryKey = UUID()
        #expect(try await fixture.runtime.launch(request).state.isLive)
    }

    @Test(arguments: ["directory", "symlink", "missing"]) func rejectedResumePreservesEndedTerminalAndNonGitFolderIdentity(replacement: String) async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let checkout = fixture.path("checkout"), backup = fixture.path("original-checkout"), other = fixture.path("other")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        let project = try #require(await fixture.runtime.store.current().projects.first)
        var changed = project.value
        changed.folders[0].selectedPath = checkout.path; changed.folders[0].canonicalPath = Paths.canonical(checkout.path)
        try await fixture.runtime.store.save(changed, expectedVersion: project.version)
        let launched = try await fixture.runtime.launch(fixture.request)
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("started").path) }
        #expect(kill(try #require(launched.processID), SIGUSR1) == 0)
        try await fixture.wait { try await fixture.runtime.terminals.inventory().first?.dead == true }
        try await fixture.runtime.reconcile()
        let ended = try await fixture.session()
        let pane = try #require(await fixture.runtime.terminals.inventory().first)
        try FileManager.default.moveItem(at: checkout, to: backup)
        switch replacement {
        case "directory": try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        case "symlink":
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: checkout, withDestinationURL: other)
        default: break
        }
        var code: String?
        do { _ = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(launched.id.uuidString)]))) }
        catch let error as ChauffeurError { code = error.code }
        #expect(code == (replacement == "missing" ? "missing_directory" : "checkout_changed"))
        #expect(try await fixture.session().launch == ended.launch)
        #expect(try await fixture.session().state == .exited)
        #expect(try await fixture.runtime.terminals.inventory().first?.paneID == pane.paneID)
        if replacement != "missing" { try FileManager.default.removeItem(at: checkout) }
        try FileManager.default.moveItem(at: backup, to: checkout)
        let resumed = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(launched.id.uuidString)]))).decode(Session.self)
        #expect(resumed.state.isLive && resumed.launch == ended.launch && resumed.nativeConversationID == ended.nativeConversationID)
        _ = try await fixture.stop()
    }

    @Test(arguments: [false, true]) func resumeRejectsReplacedCheckoutsAndAcceptsTheRestoredOriginal(additional: Bool) async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        func initializeRepository(_ directory: URL) async throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Initial"]] {
                let result = try await ProcessRunner.run("/usr/bin/git", ["-C", directory.path] + arguments)
                try #require(result.status == 0, "Git fixture failed: \(result.error)")
            }
        }
        try await initializeRepository(fixture.root)
        var request = fixture.request
        let checkout = additional ? fixture.path("additional") : fixture.root
        if additional {
            try await initializeRepository(checkout)
            let stored = try #require(await fixture.runtime.store.current().projects.first)
            var project = stored.value; project.addFolder(ProjectFolder(path: checkout.path))
            try await fixture.runtime.store.save(project, expectedVersion: stored.version)
            request.additionalFolderIDs = [project.folders.last!.id]
        }
        let launched = try await fixture.runtime.launch(request)
        _ = try await fixture.stop()
        let stopped = try await fixture.session()
        // Recreate Git at the same path while preserving the checkout directory.
        // A path/existence check alone would resume into the replacement repo.
        let originalGit = checkout.appendingPathComponent(".git")
        let savedGit = fixture.path("original-git-metadata")
        try FileManager.default.moveItem(at: originalGit, to: savedGit)
        try await initializeRepository(checkout)
        var failure: String?
        do { _ = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(launched.id.uuidString)]))) }
        catch let error as ChauffeurError { failure = error.code }
        #expect(failure == "checkout_changed")
        #expect(try await fixture.runtime.terminals.inventory().allSatisfy(\.dead))
        #expect(try await fixture.session().launch == stopped.launch)
        try FileManager.default.removeItem(at: originalGit)
        try FileManager.default.moveItem(at: savedGit, to: originalGit)
        let resumed = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(launched.id.uuidString)]))).decode(Session.self)
        #expect(resumed.state.isLive && resumed.nativeConversationID == launched.nativeConversationID)
        #expect(resumed.launch.configurationPath == launched.launch.configurationPath)
        _ = try await fixture.stop()
    }

    @Test func backgroundMetadataWatchingPreservesAnAgentWhileItsProjectIsMoved() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)
        let stored = try #require(await fixture.runtime.store.current().projects.first)
        // Exercise the runtime's ordinary background loop without an app or a
        // snapshot request that could refresh metadata on the caller's behalf.
        let observing = Task {
            while !Task.isCancelled {
                try await fixture.runtime.reconcile()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { observing.cancel() }
        var changed = stored.value; changed.name = "Renamed outside the app"
        try JSONCoding.encode(changed).write(to: URL(fileURLWithPath: stored.path), options: .atomic)
        try await fixture.wait { await fixture.runtime.store.current().projects.first?.value.name == "Renamed outside the app" }
        let directory = URL(fileURLWithPath: stored.path).deletingLastPathComponent()
        let backup = fixture.path("moved-project")
        try FileManager.default.moveItem(at: directory, to: backup)
        try await fixture.wait { await fixture.runtime.store.current().projects.isEmpty }
        let pane = try #require(await fixture.runtime.terminals.inventory().first)
        #expect(!pane.dead && pane.processID == launched.processID)
        #expect(try await fixture.session().state.isLive)
        try FileManager.default.moveItem(at: backup, to: directory)
        try await fixture.wait { await fixture.runtime.store.current().projects.first?.value.id == stored.value.id }
        #expect(try await fixture.runtime.terminals.inventory().first?.processID == launched.processID)
        observing.cancel(); _ = await observing.result
        _ = try await fixture.stop()
    }

    @Test func stopWaitsForSubmittedTerminalCreationBeforeAcknowledging() async throws {
        let fixture = try await LaunchFixture.make(gatedCreation: true); defer { fixture.cleanup() }
        try Data().write(to: fixture.path("block-creation"))
        let launch = Task { try await fixture.runtime.launch(fixture.request) }
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("creation-entered").path) }
        let stopping = Task {
            _ = try await fixture.stop()
            try Data().write(to: fixture.path("stop-finished"))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: fixture.path("stop-finished").path))
        try FileManager.default.removeItem(at: fixture.path("block-creation"))
        try await stopping.value
        #expect(await launch.result.failureCode == "launch_cancelled")
        #expect(try await fixture.runtime.terminals.inventory().isEmpty)
        #expect(try await fixture.session().state == .interrupted)
        #expect(!FileManager.default.fileExists(atPath: fixture.handoff.path))
    }
    @Test func stopDuringVersionProbePreventsLaterSpawn() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        try Data().write(to: fixture.path("block-version"))
        let launch = Task { try await fixture.runtime.launch(fixture.request) }
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("version-entered").path) }
        let probePID = try Int32(String(contentsOf: fixture.path("version-entered"), encoding: .utf8))!
        let began = ContinuousClock.now
        _ = try await fixture.stop()
        #expect(ContinuousClock.now - began < .seconds(3))
        #expect(kill(probePID, 0) != 0, "Stop must terminate the pending CLI probe")
        try FileManager.default.removeItem(at: fixture.path("block-version"))
        let result = await launch.result
        #expect(result.failureCode == "launch_cancelled")
        #expect(try await fixture.session().state == .interrupted)
        #expect(try await fixture.runtime.terminals.inventory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.path("started").path))
        let token = try String(contentsOf: fixture.path("probe-token"), encoding: .utf8)
        var accepted = false
        do { _ = try await fixture.runtime.ledger.authenticate(token); accepted = true } catch { }
        #expect(!accepted, "Cancelled startup must not retain a credential")
        #expect(try await fixture.runtime.launch(fixture.request).state == .interrupted, "Retrying the request must not create a second launch")
    }

    @Test func stopDuringHandoffCleansUpAndDoesNotPoisonExplicitResume() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        try Data().write(to: fixture.path("block-handoff"))
        let launch = Task { try await fixture.runtime.launch(fixture.request) }
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("handoff-entered").path) }
        _ = try await fixture.stop()
        #expect(await launch.result.failureCode == "launch_cancelled")
        #expect(try await fixture.session().state == .interrupted)
        #expect(try await fixture.runtime.terminals.inventory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.handoff.path))
        try FileManager.default.removeItem(at: fixture.path("handoff-entered"))
        let resuming = Task { try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(fixture.request.retryKey.uuidString)]))).decode(Session.self) }
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("handoff-entered").path) }
        _ = try await fixture.stop()
        #expect(await resuming.result.failureCode == "launch_cancelled")
        #expect(try await fixture.session().state == .interrupted)
        #expect(try await fixture.runtime.terminals.inventory().isEmpty)
        try FileManager.default.removeItem(at: fixture.path("block-handoff"))
        let resumed = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(fixture.request.retryKey.uuidString)]))).decode(Session.self)
        #expect(resumed.state == .activityUnknown)
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("started").path) }
        let capture = try await fixture.runtime.terminals.capture(sessionID: resumed.id, lines: 10)
        #expect(capture.processID == resumed.processID && capture.columns == 100 && capture.rows == 30)
        #expect(kill(try #require(resumed.processID), SIGUSR1) == 0)
        try await fixture.wait { try await fixture.runtime.terminals.inventory().first?.dead == true }
        try await fixture.runtime.reconcile()
        #expect(try await fixture.session().state == .exited, "The old Stop must not mark a resumed execution interrupted")
    }

    @Test func failedHandoffRemovesItsTerminalAndPrivatePayload() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        try Data().write(to: fixture.path("fail-handoff"))
        let result = await Task { try await fixture.runtime.launch(fixture.request) }.result
        #expect(result.failureCode == "launch_handoff_timeout")
        #expect(try await fixture.session().state == .failed)
        #expect(try await fixture.runtime.terminals.inventory().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.handoff.path))
    }

    @Test func malformedInventoryIsAnErrorInsteadOfNoSessions() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-inventory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("tmux")
        try Data("#!/bin/sh\nprintf 'unreadable pane record\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let host = try TmuxHost(runtimeDirectory: root, ctlPath: "/bin/false", environment: ["PATH": root.path])
        var code: String?
        do { _ = try await host.inventory() } catch let error as ChauffeurError { code = error.code }
        #expect(code == "terminal_inventory")
    }
}

struct ShellSessionTests {
    @Test func legacyRetentionSettingsDefaultToDiscardingClosedSessions() throws {
        let legacy = Data(#"{"scrollbackLines":1234,"snapshotBudgetBytes":1048576,"completedMessageDays":30,"maxLiveChildren":2}"#.utf8)
        let settings = try JSONCoding.decode(RetentionSettings.self, from: legacy)
        #expect(!settings.keepFinishedSessions && settings.scrollbackLines == 1234)
        #expect(!RetentionSettings().keepFinishedSessions)
    }

    @Test(arguments: [false, true], [false, true])
    func closingTabsHonorsRetentionAndFinishedSessionsCanBeDeleted(keep: Bool, shell: Bool) async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        var settings = RetentionSettings(); settings.keepFinishedSessions = keep
        _ = try await fixture.runtime.handle(IPCRequest("saveSettings", params: .from(settings)))
        let request = shell ? LaunchRequest.shell(projectID: fixture.request.projectID, groupID: fixture.request.groupID, folderID: fixture.request.folderID, title: "Shell") : fixture.request
        let session = try await fixture.runtime.launch(request)
        let params: JSONValue = .object(["sessionID": .string(session.id.uuidString)])
        await #expect(throws: ChauffeurError.self) {
            _ = try await fixture.runtime.handle(IPCRequest("deleteSession", params: params))
        }
        await fixture.runtime.maintainHistory()
        _ = try await fixture.runtime.handle(IPCRequest("closeSession", params: params))
        #expect(try await !fixture.runtime.terminals.inventory().contains { $0.sessionName == session.id.uuidString })
        let stored = await fixture.runtime.store.current().sessions.first { $0.value.id == session.id }
        if keep {
            #expect(stored?.value.state.isLive == false)
            #expect(try await fixture.runtime.snapshots.read(session.id) != nil)
            _ = try await fixture.runtime.handle(IPCRequest("deleteSession", params: params))
        } else { #expect(stored == nil) }
        await fixture.runtime.maintainHistory()
        #expect(await fixture.runtime.store.current().sessions.allSatisfy { $0.value.id != session.id })
        #expect(try await fixture.runtime.snapshots.read(session.id) == nil)
        #expect(try await fixture.runtime.snapshot()["sessions"].decode([Session].self).allSatisfy { $0.id != session.id })
    }

    @Test func shellSessionsRunTheLoginShellWithoutClaimingTheCheckout() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let project = try #require(await fixture.runtime.store.current().projects.first).value
        let request = LaunchRequest.shell(projectID: project.id, groupID: project.groups[0].id, folderID: project.folders[0].id, title: "Shell · main")
        let shell = try await fixture.runtime.launch(request)
        #expect(shell.state.isLive)
        #expect(shell.launch.preset.kind == .shell && shell.launch.preset.name == "Shell")
        #expect(shell.launch.preset.arguments == ["-l"] && shell.launch.executableVersion == "shell")
        #expect(shell.launch.preset.integration == .unavailable && shell.nativeConversationID == nil)
        #expect(shell.launch.executablePath.hasPrefix("/") && shell.launch.workingDirectory == project.folders[0].canonicalPath)
        #expect(!FileManager.default.fileExists(atPath: fixture.path("runtime/integration/\(shell.id)").path))
        // An agent still starts in the same checkout without sharing consent.
        var agent = fixture.request; agent.allowSharedCheckout = false
        let launched = try await fixture.runtime.launch(agent)
        #expect(launched.state.isLive && launched.launch.preset.kind == .claude)
        // A shell can never be resumed; its record keeps no native conversation.
        _ = try await fixture.runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(shell.id.uuidString), "force": .bool(true)])))
        try await fixture.wait { try await fixture.runtime.snapshot()["sessions"].decode([Session].self).first { $0.id == shell.id }?.state.isLive == false }
        var code: String?
        do { _ = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(shell.id.uuidString)]))) }
        catch let error as ChauffeurError { code = error.code }
        #expect(code == "resume_unavailable")
        _ = try await fixture.stop()
    }
}

private extension Result where Success == Session, Failure == Error {
    var failureCode: String? {
        if case .failure(let error) = self { return (error as? ChauffeurError)?.code }
        return nil
    }
}

private struct LaunchFixture: Sendable {
    let root: URL
    let runtime: RuntimeCoordinator
    let request: LaunchRequest
    let tmux: String
    func path(_ name: String) -> URL { root.appendingPathComponent(name) }
    var handoff: URL { path("runtime/launch-\(request.retryKey).json") }
    static func make(gatedCreation: Bool = false) async throws -> Self {
        // Keep the Unix-domain tmux socket below macOS's path-length limit.
        let root = URL(fileURLWithPath: "/tmp/chauffeur-cancel-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fixture.py")
        try Data(#"""
        #!/usr/bin/python3
        import json, os, signal, sys, time
        from pathlib import Path
        root = Path(__file__).resolve().parent
        if Path(sys.argv[0]).name == 'tmux': root = root.parent
        def mark(name, value):
            fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, 'w') as file: file.write(str(value))
        if Path(sys.argv[0]).name == 'tmux':
            if 'new-session' in sys.argv and (root / 'block-creation').exists():
                mark('creation-entered', os.getpid())
                while (root / 'block-creation').exists(): time.sleep(0.01)
            real = (root / 'real-tmux').read_text()
            os.execv(real, [real, *sys.argv[1:]])
        elif '--version' in sys.argv:
            mark('probe-token', os.environ['CHAUFFEUR_SESSION_TOKEN'])
            mark('version-entered', os.getpid())
            while (root / 'block-version').exists(): time.sleep(0.01)
            print('2.1.272 (Claude Code)')
        elif '--help' in sys.argv:
            print('--resume --add-dir')
        elif len(sys.argv) > 1 and sys.argv[1] == 'internal-exec':
            mark('handoff-entered', os.getpid())
            if (root / 'fail-handoff').exists(): sys.exit(0)
            while (root / 'block-handoff').exists(): time.sleep(0.01)
            path = Path(sys.argv[2]); payload = json.loads(path.read_text()); path.unlink()
            os.chdir(payload['directory'])
            os.execve(payload['executable'], [payload['executable'], *payload['arguments']], payload['environment'])
        else:
            signal.signal(signal.SIGUSR1, lambda *_: sys.exit(0))
            mark('started', os.getpid())
            if (root / 'unicode-output').exists():
                print((root / 'unicode-output').read_text(encoding='utf-8'), flush=True)
            while True: time.sleep(0.01)
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": root.path]
        let tmux = try Paths.executable("tmux", environment: environment)
        if gatedCreation {
            let bin = root.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: executable, to: bin.appendingPathComponent("tmux"))
            try Data(tmux.utf8).write(to: root.appendingPathComponent("real-tmux"))
            environment["PATH"] = bin.path + ":" + environment["PATH"]!
        }
        let runtime = try RuntimeCoordinator(root: root, ctlPath: executable.path, environment: environment)
        let set = PresetSet(name: "Cancellation fixture")
        let preset = AgentPreset(setID: set.id, name: "Fixture", kind: .claude, executable: executable.path, configurationDirectory: root.path)
        var project = Project(name: "Cancellation fixture", presetSetID: set.id)
        project.addFolder(ProjectFolder(path: root.path))
        try await runtime.store.save(set); try await runtime.store.save(preset); try await runtime.store.save(project)
        try await runtime.start()
        let request = LaunchRequest(projectID: project.id, groupID: project.groups[0].id, presetID: preset.id, folderID: project.folders[0].id, title: "Fixture", coordinationEnabled: false)
        return Self(root: root, runtime: runtime, request: request, tmux: tmux)
    }
    func session() async throws -> Session {
        try #require(await runtime.snapshot()["sessions"].decode([Session].self).first { $0.id == request.retryKey })
    }
    func stop() async throws -> JSONValue {
        try await runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(request.retryKey.uuidString), "force": .bool(false)])))
    }
    func wait(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ChauffeurError("fixture_timeout", "Cancellation fixture did not reach its checkpoint")
    }
    func activity(_ sessionID: UUID) async throws -> TerminalActivity {
        try await runtime.handle(IPCRequest("sessionActivity", params: .object(["sessionID": .string(sessionID.uuidString)]))).decode(TerminalActivity.self)
    }
    func sendKeys(sessionID: UUID, _ keys: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-S", path("runtime/tmux.sock").path, "-f", "/dev/null", "send-keys", "-t", sessionID.uuidString, keys, "Enter"]
        try process.run(); process.waitUntilExit()
    }
    func cleanup() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-S", path("runtime/tmux.sock").path, "kill-server"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run(); process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}
