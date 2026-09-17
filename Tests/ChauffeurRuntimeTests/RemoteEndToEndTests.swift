import Foundation
import Darwin
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient
import ChauffeurTerminalTesting
@testable import ChauffeurRuntimeKit

/// The whole remote stack the way the iPhone drives it: the real client library
/// (`PairingClient`, `RemoteHostSession`, `RemoteSessionController`, `NetworkTransport`)
/// over real TLS-PSK sockets on 127.0.0.1, against a real `RuntimeCoordinator` that
/// launches shells in tmux, with `RemoteOperationHandlers` wired as `RuntimeMain` does.
@MainActor
struct RemoteEndToEndTests {
    @Test func pairListAndLaunchOverTLS() async throws {
        let fixture = try await EndToEndFixture.make(); defer { fixture.cleanup() }
        let host = try await fixture.pair()
        #expect(host.port == fixture.port && host.host == "127.0.0.1" && host.name == "Test Mac")
        #expect(host.hostID == (try fixture.configuration().hostID))
        #expect(host.remoteAccessKey == (try fixture.configuration().key))
        #expect(await fixture.service.status().devices.map(\.name) == ["Test iPhone"])

        let phone = try await fixture.connectedSession(host)
        guard case .connected(let info) = phone.connectionState else { Issue.record("not connected: \(phone.connectionState)"); return }
        #expect(info.protocolVersion == RemoteProtocol.version && info.hostID == host.hostID && info.hostName == "Test Mac")
        #expect(info.capabilities == RemoteProtocol.capabilities)

        // The inventory the phone lists right after connecting: the project, its repository folder, a main checkout, no live sessions.
        let inventory = try #require(phone.inventory)
        #expect(inventory.hostName == "Test Mac")
        let project = try #require(inventory.projects.first)
        #expect(inventory.projects.count == 1 && project.id == fixture.project.id && project.name == fixture.project.name)
        let folder = try #require(project.folders.first)
        #expect(project.folders.count == 1 && folder.id == fixture.folder.id && folder.path == fixture.folder.canonicalPath)
        #expect(folder.isRepository && folder.availability == .available)
        #expect(folder.checkouts.map(\.kind) == [.main] && folder.checkouts.first?.branch == "main")
        #expect(inventory.sessions.filter { $0.state.isLive }.isEmpty)

        // Launch a shell in a new worktree; the same request again is idempotent.
        let key = UUID()
        let request = fixture.shellLaunch(key: key, branch: "e2e-branch")
        let status = try await phone.launch(request)
        #expect(status.phase == .completed && status.error == nil, "\(status)")
        let sessionID = try #require(status.sessionID)
        let worktreeID = try #require(status.worktreeID)
        let again = try await phone.launch(request)
        #expect(again.phase == .completed && again.sessionID == sessionID && again.worktreeID == worktreeID)

        await fixture.runtime.reconcileWorktrees()
        await phone.refreshInventory()
        let refreshed = try #require(phone.inventory)
        let checkouts = try #require(refreshed.projects.first?.folders.first?.checkouts)
        #expect(checkouts.count == 2)
        #expect(checkouts.contains { $0.kind == .worktree && $0.worktreeID == worktreeID && $0.branch == "e2e-branch" && $0.managed })
        let live = refreshed.sessions.filter { $0.state.isLive }
        #expect(live.count == 1 && refreshed.sessions.count == 1)
        let shell = try #require(live.first)
        #expect(shell.id == sessionID && shell.kind == .shell && shell.worktreeID == worktreeID && shell.branch == "e2e-branch")
        #expect(shell.title == "Shell · e2e-branch" && shell.projectID == project.id && shell.folderID == folder.id)
        #expect(!shell.attached)
        let worktrees = await fixture.runtime.store.reload().worktrees
        #expect(worktrees.count == 1 && worktrees.first?.value.id == worktreeID && worktrees.first?.value.branch == "e2e-branch")
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 2)

        phone.disconnect()
        try await eventually { await fixture.service.status().devices.first?.connected == false }
        await fixture.teardown()
    }

    @Test func terminalRoundTripAndHandoff() async throws {
        let fixture = try await EndToEndFixture.make(); defer { fixture.cleanup() }
        let host = try await fixture.pair()
        let phone = try await fixture.connectedSession(host)
        let launched = try await phone.launch(fixture.shellLaunch(key: UUID(), branch: "e2e-terminal"))
        let sessionID = try #require(launched.sessionID)

        let adapter = FakeTerminalEngineAdapter()
        let terminal = try phone.makeTerminal(sessionID: sessionID, adapter: adapter)
        await terminal.attach(takeControl: false)
        guard case .attached(let generation) = terminal.state else { Issue.record("attach failed: \(terminal.state)"); return }
        #expect(adapter.isInputEnabled)
        #expect(await fixture.runtime.terminals.currentGeneration(sessionID: sessionID) == generation)
        // Attaching replays the current screen: the shell prompt arrives before anything is typed.
        try await eventually { !adapter.fed.isEmpty }

        // The quotes split the typed text so the marker only appears once the shell ran the command.
        adapter.simulateTypedInput(Data("echo e2e-mark''er-42\r".utf8))
        try await eventually { adapter.screenText.contains("e2e-marker-42") }
        #expect(try await fixture.runtime.terminals.capture(sessionID: sessionID, lines: 100).screen.contains("e2e-marker-42"))
        await phone.refreshInventory()
        #expect(phone.inventory?.sessions.first { $0.id == sessionID }?.attached == true)

        // Another device takes control over its own connection.
        let desktop = try await fixture.connectedSession(host)
        let secondAdapter = FakeTerminalEngineAdapter()
        let secondTerminal = try desktop.makeTerminal(sessionID: sessionID, adapter: secondAdapter)
        await secondTerminal.attach(takeControl: true)
        guard case .attached(let secondGeneration) = secondTerminal.state else { Issue.record("takeover failed: \(secondTerminal.state)"); return }
        #expect(secondGeneration > generation)
        try await eventually { if case .controlLost = terminal.state { return true } else { return false } }
        #expect(!adapter.isInputEnabled && secondAdapter.isInputEnabled)

        // Input on the device that lost control goes nowhere; the controller's input still lands.
        let generated = adapter.generatedInput.count
        adapter.simulateTypedInput(Data("echo lost-mark''er-77\r".utf8))
        #expect(adapter.generatedInput.count == generated)
        secondAdapter.simulateTypedInput(Data("echo second-mark''er-88\r".utf8))
        try await eventually { secondAdapter.screenText.contains("second-marker-88") }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!secondAdapter.screenText.contains("lost-mark"))
        #expect(!(try await fixture.runtime.terminals.capture(sessionID: sessionID, lines: 100).screen.contains("lost-mark")))

        // Coming back to the foreground never steals the terminal back.
        await terminal.handleForeground()
        guard case .controlLost = terminal.state else { Issue.record("handleForeground reattached: \(terminal.state)"); return }

        // An explicit take-control does.
        await terminal.takeControl()
        guard case .attached(let retaken) = terminal.state else { Issue.record("takeControl failed: \(terminal.state)"); return }
        #expect(retaken > secondGeneration)
        try await eventually { if case .controlLost = secondTerminal.state { return true } else { return false } }
        #expect(adapter.isInputEnabled && !secondAdapter.isInputEnabled)
        adapter.simulateTypedInput(Data("echo back-mark''er-99\r".utf8))
        try await eventually { adapter.screenText.contains("back-marker-99") }

        await terminal.detach()
        #expect(terminal.state == .idle)
        try await eventually { await fixture.runtime.terminals.currentGeneration(sessionID: sessionID) == nil }
        phone.disconnect(); desktop.disconnect()
        await fixture.teardown()
    }

    @Test func unauthorizedAndRevoked() async throws {
        let fixture = try await EndToEndFixture.make(); defer { fixture.cleanup() }
        // A made-up device on the right key is refused at hello.
        let intruder = SavedHost(hostID: UUID(), name: "Test Mac", host: "127.0.0.1", port: fixture.port, remoteAccessKey: try fixture.configuration().key,
                                 deviceID: UUID(), deviceToken: RemoteDeviceToken.generate(), pairedAt: Date())
        let raw = rawConnection(intruder)
        do {
            _ = try await raw.connect(hello: hello(intruder))
            Issue.record("unknown device connected")
        } catch let error as RemoteClientError {
            guard case .unauthorized = error else { Issue.record("expected unauthorized, got \(error)"); return }
        }
        let impostor = RemoteHostSession(host: intruder, journal: InMemoryOperationJournal())
        await impostor.connect()
        #expect(impostor.connectionState == .unavailable(message: RemoteClientError.unauthorized("").userMessage))
        #expect(impostor.inventory == nil)
        #expect(await fixture.service.status().devices.isEmpty)

        // A paired phone loses its live connection and cannot come back once revoked.
        let host = try await fixture.pair()
        let phone = try await fixture.connectedSession(host)
        try await eventually { await fixture.service.status().devices.first?.connected == true }
        let revoked = try await fixture.service.revokeDevice(host.deviceID)
        #expect(revoked.devices.isEmpty)
        try await eventually { if case .connected = phone.connectionState { return false } else { return true } }
        switch phone.connectionState {
        case .unavailable, .disconnected: break
        default: Issue.record("unexpected state after revocation: \(phone.connectionState)")
        }
        #expect(phone.inventoryIsStale)
        let retry = rawConnection(host)
        do {
            _ = try await retry.connect(hello: hello(host))
            Issue.record("revoked device connected")
        } catch let error as RemoteClientError {
            guard case .unauthorized = error else { Issue.record("expected unauthorized, got \(error)"); return }
        }
        let reconnect = RemoteHostSession(host: host, journal: InMemoryOperationJournal())
        await reconnect.connect()
        #expect(reconnect.connectionState == .unavailable(message: RemoteClientError.unauthorized("").userMessage))

        // A wrong pairing code never completes the TLS handshake and does not end pairing on its own.
        let status = try await fixture.service.beginPairing()
        let pairing = try #require(status.pairing)
        var wrong = PairingCode.generate().display
        while wrong == pairing.code { wrong = PairingCode.generate().display }
        await #expect(throws: (any Error).self) {
            _ = try await PairingClient.pair(host: "127.0.0.1", pairingPort: pairing.port, code: wrong, deviceName: "Intruder")
        }
        let after = await fixture.service.status()
        #expect(after.pairing?.code == pairing.code && after.devices.isEmpty)
        _ = await fixture.service.cancelPairing()
        await fixture.teardown()
    }

    @Test func lostLaunchResponseIsReconciled() async throws {
        let fixture = try await EndToEndFixture.make(); defer { fixture.cleanup() }
        let host = try await fixture.pair()
        let journal = InMemoryOperationJournal()
        // The phone's connection drops every byte from the Mac once the launch is sent, so the host
        // completes the launch while the client only sees a timeout.
        let lossy = DroppingTransport(inner: networkTransport(host))
        let phone = RemoteHostSession(host: host, journal: journal, makeConnection: { _ in RemoteConnection(transport: lossy, requestTimeout: .seconds(2)) })
        await phone.connect()
        guard case .connected = phone.connectionState else { Issue.record("not connected: \(phone.connectionState)"); return }
        lossy.dropIncoming()
        let key = UUID()
        let request = fixture.shellLaunch(key: key, branch: "e2e-lost")
        await #expect(throws: RemoteClientError.timeout) { _ = try await phone.launch(request) }
        #expect(journal.pendingKeys() == [key])
        try await eventually { await fixture.handlers.operationStatus(key: key)?.phase == .completed }
        let recorded = try #require(await fixture.handlers.operationStatus(key: key))
        let sessionID = try #require(recorded.sessionID)
        let worktreeID = try #require(recorded.worktreeID)
        phone.disconnect()

        // Reconnecting reconciles the journal before anything else.
        let fresh = RemoteHostSession(host: host, journal: journal)
        await fresh.connect()
        guard case .connected = fresh.connectionState else { Issue.record("not connected: \(fresh.connectionState)"); return }
        #expect(journal.pendingKeys().isEmpty)
        await fresh.reconcilePendingOperations()
        #expect(journal.pendingKeys().isEmpty)
        let raw = rawConnection(host)
        _ = try await raw.connect(hello: hello(host))
        let result = try await raw.request(.getOperationStatus(OperationStatusRequest(operationKey: key)))
        guard case .operation(let status) = result else { Issue.record("expected operation status, got \(result.kind)"); return }
        #expect(status.phase == .completed && status.sessionID == sessionID && status.worktreeID == worktreeID)
        // Retrying the very same request after the fact still does not launch twice.
        let retried = try await fresh.launch(request)
        #expect(retried.phase == .completed && retried.sessionID == sessionID && retried.worktreeID == worktreeID)

        await fixture.runtime.reconcileWorktrees()
        await fresh.refreshInventory()
        let inventory = try #require(fresh.inventory)
        #expect(inventory.sessions.filter { $0.branch == "e2e-lost" }.map(\.id) == [sessionID])
        #expect(inventory.sessions.count == 1)
        let checkouts = try #require(inventory.projects.first?.folders.first?.checkouts)
        #expect(checkouts.filter { $0.branch == "e2e-lost" }.map(\.worktreeID) == [worktreeID])
        #expect(await fixture.runtime.store.reload().worktrees.count == 1)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 2)
        await raw.close()
        fresh.disconnect()
        await fixture.teardown()
    }

    @Test func protocolMismatchIsReported() async throws {
        let fixture = try await EndToEndFixture.make(); defer { fixture.cleanup() }
        let host = try await fixture.pair()
        let raw = rawConnection(host)
        do {
            _ = try await raw.connect(hello: hello(host, protocolVersion: RemoteProtocol.version + 1))
            Issue.record("mismatched client connected")
        } catch let error as RemoteClientError {
            guard case .protocolMismatch(let hostVersion, let clientVersion) = error else { Issue.record("expected protocolMismatch, got \(error)"); return }
            #expect(hostVersion == RemoteProtocol.version && clientVersion == RemoteProtocol.version)
        }
        try await eventually { if case .failed = await raw.state { return true } else { return false } }
        // The host drops the connection after the refusal, and the device is not marked connected.
        #expect(await fixture.service.status().devices.first?.connected == false)
        let good = rawConnection(host)
        #expect(try await good.connect(hello: hello(host)).protocolVersion == RemoteProtocol.version)
        await good.close()
        await fixture.teardown()
    }

    @Test func restartPreservesPairing() async throws {
        let fixture = try await EndToEndFixture.make(); defer { fixture.cleanup() }
        let host = try await fixture.pair()
        let before = try await fixture.connectedSession(host)
        #expect(before.inventory?.projects.first?.id == fixture.project.id)
        before.disconnect()
        try await eventually { if case .disconnected = before.connectionState { return true } else { return false } }
        await fixture.service.shutdown()
        await #expect(throws: (any Error).self) { _ = try await rawConnection(host).connect(hello: hello(host)) }

        // A new runtime process: fresh handlers and service over the same root.
        let (handlers, service) = await EndToEndFixture.wire(root: fixture.root, runtime: fixture.runtime)
        let loaded = await service.status()
        #expect(loaded.enabled && !loaded.listening && loaded.port == fixture.port && loaded.devices.map(\.id) == [host.deviceID])
        await service.startIfEnabled()
        #expect(await service.status().listening)
        let after = RemoteHostSession(host: host, journal: InMemoryOperationJournal())
        await after.connect()
        guard case .connected(let info) = after.connectionState else { Issue.record("not connected: \(after.connectionState)"); return }
        #expect(info.hostID == host.hostID && info.hostName == "Test Mac")
        let inventory = try #require(after.inventory)
        #expect(inventory.projects.map(\.id) == [fixture.project.id])
        #expect(inventory.projects.first?.folders.first?.checkouts.map(\.kind) == [.main])
        #expect(await service.status().devices.first?.connected == true)
        #expect(await handlers.currentRevision() >= 1)
        after.disconnect()
        await service.shutdown()
    }
}

// MARK: - Fixture

private struct EndToEndFixture: Sendable {
    let root: URL
    let runtime: RuntimeCoordinator
    let project: Project
    let handlers: RemoteOperationHandlers
    let service: RemoteAccessService
    let port: Int
    let tmux: String
    var repo: URL { root.appendingPathComponent("repo") }
    var folder: ProjectFolder { project.folders[0] }

    static func make() async throws -> Self {
        // Keep the Unix-domain tmux socket below macOS's path-length limit.
        let root = URL(fileURLWithPath: "/tmp/chauffeur-e2e-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "core.hooksPath", "/dev/null"], ["config", "commit.gpgsign", "false"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"]] {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + args)
            guard result.status == 0 else { throw ChauffeurError("fixture_git", result.error) }
        }
        // The exec helper only needs to hand the shell its payload; agents are never launched here.
        let helper = root.appendingPathComponent("ctl.py")
        try Data(#"""
        #!/usr/bin/python3
        import json, os, sys
        from pathlib import Path
        if len(sys.argv) > 1 and sys.argv[1] == 'internal-exec':
            path = Path(sys.argv[2]); payload = json.loads(path.read_text()); path.unlink()
            os.chdir(payload['directory'])
            os.execve(payload['executable'], [payload['executable'], *payload['arguments']], payload['environment'])
        sys.exit(1)
        """#.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": root.path]
        let tmux = try Paths.executable("tmux", environment: environment)
        let runtime = try RuntimeCoordinator(root: root, ctlPath: helper.path, environment: environment)
        let set = PresetSet(name: "E2E fixture")
        let preset = AgentPreset(setID: set.id, name: "Unavailable agent", kind: .claude, executable: root.appendingPathComponent("missing-cli").path, configurationDirectory: root.path)
        var project = Project(name: "E2E fixture", presetSetID: set.id)
        project.addFolder(ProjectFolder(path: repo.path))
        try await runtime.store.save(set); try await runtime.store.save(preset); try await runtime.store.save(project)
        try await runtime.start()
        await runtime.reconcileWorktrees()
        let (handlers, service) = await wire(root: root, runtime: runtime)
        let port = try freePortPair()
        let status = try await service.setEnabled(true, port: port)
        guard status.listening else { throw ChauffeurError("fixture_listener", status.error ?? "Remote access is not listening") }
        return Self(root: root, runtime: runtime, project: project, handlers: handlers, service: service, port: port, tmux: tmux)
    }

    /// The dispatcher wiring `RuntimeMain` performs on startup.
    static func wire(root: URL, runtime: RuntimeCoordinator) async -> (RemoteOperationHandlers, RemoteAccessService) {
        let terminals = await runtime.terminals
        let handlers = RemoteOperationHandlers(runtime: runtime, root: root, hostName: "Test Mac") { sessionID in
            await terminals.currentGeneration(sessionID: sessionID) != nil
        }
        await handlers.reconcileAfterRestart()
        let service = RemoteAccessService(root: root, runtime: runtime, dispatcher: handlers, hostName: "Test Mac")
        return (handlers, service)
    }

    func configuration() throws -> RemoteAccessConfiguration { try RemoteAccessStore(root: root).load() }

    /// The pairing flow as the phone performs it: read the code off the Mac, connect to the pairing port with the real client.
    func pair(deviceName: String = "Test iPhone") async throws -> SavedHost {
        let status = try await service.beginPairing()
        let pairing = try #require(status.pairing)
        #expect(pairing.port == port + 1)
        let host = try await PairingClient.pair(host: "127.0.0.1", pairingPort: pairing.port, code: pairing.code, deviceName: deviceName)
        try await eventually { await service.status().pairing == nil }
        return host
    }

    @MainActor func connectedSession(_ host: SavedHost, journal: any PendingOperationJournal = InMemoryOperationJournal()) async throws -> RemoteHostSession {
        let session = RemoteHostSession(host: host, journal: journal)
        await session.connect()
        guard case .connected = session.connectionState else { throw ChauffeurError("fixture_connect", "Phone did not connect: \(session.connectionState)") }
        return session
    }

    func shellLaunch(key: UUID, branch: String) -> LaunchOperationRequest {
        let worktree = WorktreeCreationSpec(branch: branch, baseRef: "HEAD")
        let launch = LaunchSpec(projectID: project.id, folderID: folder.id, agentPresetID: nil)
        return LaunchOperationRequest(operationKey: key, fingerprint: LaunchOperationRequest.computeFingerprint(newWorktree: worktree, launch: launch), newWorktree: worktree, launch: launch)
    }

    func teardown() async { await service.shutdown() }

    func cleanup() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-S", root.appendingPathComponent("runtime/tmux.sock").path, "kill-server"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run(); process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Helpers

private func hello(_ host: SavedHost, protocolVersion: Int = RemoteProtocol.version) -> HelloRequest {
    HelloRequest(deviceID: host.deviceID, deviceToken: host.deviceToken, clientName: "E2E", clientVersion: "1.0", protocolVersion: protocolVersion, capabilities: RemoteProtocol.capabilities)
}

private func networkTransport(_ host: SavedHost) -> NetworkTransport {
    NetworkTransport(endpoint: RemoteEndpoint(host: host.host, port: host.port), presharedKey: host.remoteAccessKey)
}

private func rawConnection(_ host: SavedHost) -> RemoteConnection {
    RemoteConnection(transport: networkTransport(host))
}

/// Polls every 50 ms for up to 20 s.
@MainActor
private func eventually(_ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while true {
        if try await condition() { return }
        guard ContinuousClock.now < deadline else { throw ChauffeurError("test_timeout", "Condition was not reached in time") }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// A main port whose pairing port (main + 1) is free as well, checked by binding both and releasing them.
private func freePortPair() throws -> Int {
    for _ in 0..<100 {
        let port = Int.random(in: 20000...60000)
        if canBind(port), canBind(port + 1) { return port }
    }
    throw ChauffeurError("fixture_port", "No free port pair found")
}

private func canBind(_ port: Int) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    address.sin_addr.s_addr = INADDR_ANY
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
}

/// Wraps a real transport and, once told to, swallows every byte from the host: the request
/// reaches the Mac, the response never reaches the client. Nothing is re-enabled afterwards
/// because a resumed stream could start mid-frame.
private final class DroppingTransport: ChauffeurRemoteClient.RemoteTransport, @unchecked Sendable {
    let events: AsyncStream<RemoteTransportEvent>
    private let inner: any ChauffeurRemoteClient.RemoteTransport
    private let lock = NSLock()
    private var dropping = false
    private var pump: Task<Void, Never>?

    init(inner: any ChauffeurRemoteClient.RemoteTransport) {
        self.inner = inner
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteTransportEvent.self, bufferingPolicy: .unbounded)
        events = stream
        pump = Task { [weak self] in
            for await event in inner.events {
                if case .bytes = event, self?.isDropping == true { continue }
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    private var isDropping: Bool { lock.withLock { dropping } }
    func dropIncoming() { lock.withLock { dropping = true } }
    func start() { inner.start() }
    func send(_ data: Data) async throws { try await inner.send(data) }
    func cancel() { inner.cancel() }
}
