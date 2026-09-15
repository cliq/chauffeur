import Foundation
import Darwin
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct LaunchCancellationTests {
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
    func cleanup() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-S", path("runtime/tmux.sock").path, "kill-server"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run(); process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}
