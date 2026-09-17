import Foundation
import Network
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

/// Records every forwarded operation and lets a test bump the inventory revision.
actor FakeDispatcher: RemoteOperationDispatching {
    struct Call: Equatable { let kind: String; let deviceID: UUID }
    private(set) var calls: [Call] = []
    private var revision: UInt64 = 1
    func handle(_ operation: RemoteOperation, deviceID: UUID) async -> Result<RemoteResult, RemoteError> {
        calls.append(Call(kind: operation.kind, deviceID: deviceID))
        return .success(.ack)
    }
    func inventoryRevision() async -> UInt64 { revision }
    func setRevision(_ value: UInt64) { revision = value }
}

enum RemoteTestClientError: Error {
    case timeout
    case closed
    case unexpectedFrame(RemoteFrameType)
    case unexpectedResult
}

/// Minimal iPhone stand-in: one TLS-PSK connection, frame encoding and a
/// timeout-guarded frame reader. Frames skipped while waiting for a response
/// are kept in `skipped` so tests can check ordering guarantees.
final class RemoteTestClient: @unchecked Sendable {
    private let transport: RemoteTransport
    private let lock = NSLock()
    private var decoder = RemoteFrameDecoder()
    private var pending: [RemoteFrame] = []
    private(set) var skipped: [RemoteFrame] = []

    init(port: Int, key: Data) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: RemoteTLS.parameters(psk: key))
        transport = RemoteTransport(connection: connection, label: "test-client")
    }

    func connect(timeout: TimeInterval = 5) async throws { try await transport.start(timeout: timeout) }
    func cancel() { transport.cancel() }

    func send(_ frame: RemoteFrame) async throws { try await transport.send(RemoteFraming.encode(frame)) }

    @discardableResult func send(_ operation: RemoteOperation) async throws -> UUID {
        let request = RemoteRequest(operation: operation)
        try await send(RemoteFrame(type: .request, payload: try RemoteJSON.encode(request)))
        return request.id
    }

    func nextFrame(timeout: TimeInterval = 15) async throws -> RemoteFrame {
        while true {
            if let frame = lock.withLock({ pending.isEmpty ? nil : pending.removeFirst() }) { return frame }
            let transport = self.transport
            let chunk = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask { try await transport.receive(maximumLength: 64 * 1024) }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    transport.cancel()
                    throw RemoteTestClientError.timeout
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            guard let chunk else { throw RemoteTestClientError.closed }
            let frames = try decoder.append(chunk)
            lock.withLock { pending.append(contentsOf: frames) }
        }
    }

    func response(for id: UUID, timeout: TimeInterval = 15) async throws -> RemoteResponse {
        while true {
            let frame = try await nextFrame(timeout: timeout)
            if frame.type == .response {
                let response = try RemoteJSON.decode(RemoteResponse.self, from: frame.payload)
                if response.id == id { return response }
            }
            lock.withLock { skipped.append(frame) }
        }
    }

    func request(_ operation: RemoteOperation, timeout: TimeInterval = 15) async throws -> RemoteResponse {
        try await response(for: try await send(operation), timeout: timeout)
    }

    func nextEvent(timeout: TimeInterval = 15) async throws -> RemoteEvent {
        while true {
            let frame = try await nextFrame(timeout: timeout)
            if frame.type == .event { return try RemoteJSON.decode(RemoteEvent.self, from: frame.payload) }
            lock.withLock { skipped.append(frame) }
        }
    }

    /// The server ended the connection: either a clean close or a reset.
    func expectClosed(timeout: TimeInterval = 15) async throws {
        do { _ = try await nextFrame(timeout: timeout) }
        catch RemoteTestClientError.closed { return }
        catch is RemoteTransportError { return }
        throw RemoteTestClientError.unexpectedResult
    }
}

private struct Fixture {
    let root: URL
    let runtime: RuntimeCoordinator
    let port: Int

    static func make() async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-remote-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = try RuntimeCoordinator(root: root, ctlPath: "/bin/false", environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": root.path])
        try await runtime.start()
        return Fixture(root: root, runtime: runtime, port: Int.random(in: 20000...60000))
    }

    func service(dispatcher: any RemoteOperationDispatching = UnavailableDispatcher(), pairingTimeout: TimeInterval = 120) -> RemoteAccessService {
        RemoteAccessService(root: root, runtime: runtime, dispatcher: dispatcher, hostName: "Test Mac", pairingTimeout: pairingTimeout)
    }

    func key() throws -> Data { try RemoteAccessStore(root: root).load().key }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func eventually(_ condition: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<250 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw ChauffeurError("test_timeout", "Condition was not reached in time")
}

/// Runs the whole pairing handshake and returns what the phone would keep.
private func pair(_ service: RemoteAccessService, deviceName: String = "Test iPhone") async throws -> PairingResult {
    let status = try await service.beginPairing()
    let pairing = try #require(status.pairing)
    let code = try #require(PairingCode(pairing.code))
    let client = RemoteTestClient(port: pairing.port, key: code.derivedKey)
    try await client.connect()
    let response = try await client.request(.pair(PairRequest(deviceName: deviceName, protocolVersion: RemoteProtocol.version)))
    client.cancel()
    guard case .pairing(let result)? = response.result else { throw RemoteTestClientError.unexpectedResult }
    return result
}

private func hello(_ result: PairingResult, protocolVersion: Int = RemoteProtocol.version) -> RemoteOperation {
    .hello(HelloRequest(deviceID: result.deviceID, deviceToken: result.deviceToken, clientName: "Tests", clientVersion: "1.0", protocolVersion: protocolVersion))
}

private func connectedClient(_ fixture: Fixture, _ result: PairingResult) async throws -> RemoteTestClient {
    let client = RemoteTestClient(port: fixture.port, key: try fixture.key())
    try await client.connect()
    let response = try await client.request(hello(result))
    guard case .hostInfo? = response.result else { throw RemoteTestClientError.unexpectedResult }
    return client
}

struct RemoteAccessServiceTests {
    @Test func disabledByDefaultDoesNotListen() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        await service.startIfEnabled()
        let status = await service.status()
        #expect(!status.enabled && !status.listening)
        #expect(status.port == RemoteAccessConfiguration.defaultPort(for: .current))
        #expect(status.devices.isEmpty && status.pairing == nil && status.error == nil)
        #expect(status.hostName == "Test Mac")
        #expect(status.keyFingerprint.count == 16)
        await #expect(throws: ChauffeurError.self) { _ = try await service.beginPairing() }
        #expect(!FileManager.default.fileExists(atPath: RemoteAccessStore(root: fixture.root).url.path))
    }

    @Test func enablingListensAndPortChangesRequireDisabling() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        var status = try await service.setEnabled(true, port: fixture.port)
        #expect(status.enabled && status.listening && status.port == fixture.port && status.error == nil)
        await #expect(throws: ChauffeurError.self) { _ = try await service.setEnabled(true, port: fixture.port + 2) }
        await #expect(throws: ChauffeurError.self) { _ = try await service.setEnabled(false, port: 80) }
        #expect(try RemoteAccessStore(root: fixture.root).load().enabled)
        let snapshot = try await fixture.runtime.snapshot()
        #expect(snapshot["remoteAccess"] == .null)
        await fixture.runtime.attachRemoteAccess(service)
        let attached = try await fixture.runtime.handle(IPCRequest("remoteAccessStatus")).decode(RemoteAccessStatus.self)
        #expect(attached.listening && attached.port == fixture.port)
        #expect(try await fixture.runtime.snapshot()["remoteAccess"].decode(RemoteAccessStatus.self).listening)
        status = try await service.setEnabled(false, port: nil)
        #expect(!status.enabled && !status.listening)
        let client = RemoteTestClient(port: fixture.port, key: try fixture.key())
        await #expect(throws: (any Error).self) { try await client.connect(timeout: 3) }
        await service.shutdown()
    }

    @Test func helloFromAnUnknownDeviceIsUnauthorizedAndDisconnected() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let client = RemoteTestClient(port: fixture.port, key: try fixture.key())
        try await client.connect()
        let unknown = PairingResult(remoteAccessKey: Data(), deviceID: UUID(), deviceToken: RemoteDeviceToken.generate(), mainPort: fixture.port, hostID: UUID(), hostName: "")
        let response = try await client.request(hello(unknown))
        #expect(response.result == nil)
        #expect(response.error?.code == "unauthorized")
        try await client.expectClosed()
        #expect(await service.status().devices.isEmpty)
        await service.shutdown()
    }

    @Test func pairingThenHelloReturnsHostInfoAndMarksTheDeviceConnected() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let result = try await pair(service)
        #expect(result.remoteAccessKey == (try fixture.key()))
        #expect(result.mainPort == fixture.port)
        #expect(result.hostName == "Test Mac")
        var status = await service.status()
        #expect(status.pairing == nil)
        #expect(status.devices.map(\.name) == ["Test iPhone"])
        #expect(status.devices.first?.connected == false)
        #expect(try RemoteAccessStore(root: fixture.root).load().devices.first?.tokenHash == RemoteDeviceToken.hash(result.deviceToken))

        let client = RemoteTestClient(port: fixture.port, key: try fixture.key())
        try await client.connect()
        let response = try await client.request(hello(result))
        guard case .hostInfo(let info)? = response.result else { Issue.record("expected hostInfo, got \(response)"); return }
        #expect(info.protocolVersion == RemoteProtocol.version)
        #expect(info.hostID == result.hostID)
        #expect(info.hostName == "Test Mac")
        #expect(info.capabilities == RemoteProtocol.capabilities)
        #expect(info.runtimeVersion == RuntimeVersion.current)
        status = await service.status()
        #expect(status.devices.first?.connected == true)
        #expect(status.devices.first?.lastSeenAt != nil)
        // A second hello on an authenticated connection is refused without dropping it.
        let again = try await client.request(hello(result))
        #expect(again.error?.code == "invalid_state")
        try await client.send(RemoteFrame(type: .ping, payload: Data("ping".utf8)))
        let pong = try await client.nextFrame()
        #expect(pong == RemoteFrame(type: .pong, payload: Data("ping".utf8)))
        client.cancel()
        try await eventually { await service.status().devices.first?.connected == false }
        await service.shutdown()
    }

    @Test func wrongKeyFailsTheHandshake() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let client = RemoteTestClient(port: fixture.port, key: RemoteAccessCrypto.randomBytes(32))
        await #expect(throws: RemoteTransportError.self) { try await client.connect(timeout: 5) }
        // The listener is unaffected: a correct key still connects.
        let good = RemoteTestClient(port: fixture.port, key: try fixture.key())
        try await good.connect()
        good.cancel()
        await service.shutdown()
    }

    @Test func protocolMismatchInHelloIsRejected() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let result = try await pair(service)
        let client = RemoteTestClient(port: fixture.port, key: try fixture.key())
        try await client.connect()
        let response = try await client.request(hello(result, protocolVersion: 99))
        #expect(response.error?.code == "protocol_mismatch")
        #expect(response.error?.message == "Host protocol \(RemoteProtocol.version), client 99")
        try await client.expectClosed()
        await service.shutdown()
    }

    @Test func firstFrameMustBeHello() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let client = RemoteTestClient(port: fixture.port, key: try fixture.key())
        try await client.connect()
        let response = try await client.request(.listInventory(ListInventoryRequest()))
        #expect(response.error?.code == "hello_required")
        try await client.expectClosed()
        await service.shutdown()
    }

    @Test func revokingADeviceNotifiesItsConnectionAndRefusesItLater() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let result = try await pair(service)
        let client = try await connectedClient(fixture, result)
        await #expect(throws: ChauffeurError.self) { _ = try await service.revokeDevice(UUID()) }
        let status = try await service.revokeDevice(result.deviceID)
        #expect(status.devices.isEmpty)
        #expect(try await client.nextEvent() == .accessRevoked)
        try await client.expectClosed()
        try await eventually { await service.status().devices.isEmpty }
        let again = RemoteTestClient(port: fixture.port, key: try fixture.key())
        try await again.connect()
        #expect(try await again.request(hello(result)).error?.code == "unauthorized")
        await service.shutdown()
    }

    @Test func nonTerminalOperationsReachTheDispatcherAndInventoryChangesAreBroadcast() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let dispatcher = FakeDispatcher()
        let service = fixture.service(dispatcher: dispatcher)
        _ = try await service.setEnabled(true, port: fixture.port)
        let result = try await pair(service)
        let client = try await connectedClient(fixture, result)
        let response = try await client.request(.listInventory(ListInventoryRequest(sinceRevision: 3)))
        #expect(response.result == .ack)
        #expect(await dispatcher.calls == [.init(kind: "listInventory", deviceID: result.deviceID)])
        // Pair and hello never reach the dispatcher.
        let pairAttempt = try await client.request(.pair(PairRequest(deviceName: "x", protocolVersion: 1)))
        #expect(pairAttempt.error?.code == "unsupported_operation")
        #expect(await dispatcher.calls.count == 1)
        await dispatcher.setRevision(7)
        #expect(try await client.nextEvent(timeout: 5) == .inventoryChanged(revision: 7))
        client.cancel()
        await service.shutdown()
    }

    @Test func defaultDispatcherRejectsForwardedOperations() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let result = try await pair(service)
        let client = try await connectedClient(fixture, result)
        let response = try await client.request(.getOperationStatus(OperationStatusRequest(operationKey: UUID())))
        #expect(response.error?.code == "unsupported_operation")
        client.cancel()
        await service.shutdown()
    }

    @Test func terminalOperationsOnUnknownSessionsFailCleanly() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let result = try await pair(service)
        let client = try await connectedClient(fixture, result)
        let attach = try await client.request(.attachTerminal(AttachTerminalRequest(sessionID: UUID(), cols: 80, rows: 24)))
        #expect(attach.result == nil)
        #expect(attach.error?.code == "not_live")
        let resize = try await client.request(.terminalResize(TerminalResizeRequest(generation: 42, cols: 80, rows: 24)))
        #expect(resize.error?.code == "attachment_lost")
        let detach = try await client.request(.detachTerminal(DetachTerminalRequest(generation: 42)))
        #expect(detach.result == .ack)
        // Input for an unknown generation is dropped without ending the connection.
        try await client.send(RemoteFrame(type: .input, payload: TerminalFramePayload(generation: 42, sequence: 1, bytes: Data("x".utf8)).encoded()))
        try await client.send(RemoteFrame(type: .ping, payload: Data()))
        #expect(try await client.nextFrame().type == .pong)
        client.cancel()
        await service.shutdown()
    }

    @Test func restartLoadsTheSameKeyAndDevices() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let first = fixture.service()
        _ = try await first.setEnabled(true, port: fixture.port)
        let result = try await pair(first)
        let before = await first.status()
        await first.shutdown()
        let second = fixture.service()
        let loaded = await second.status()
        #expect(loaded.keyFingerprint == before.keyFingerprint)
        #expect(loaded.enabled && !loaded.listening && loaded.port == fixture.port)
        #expect(loaded.devices.map(\.id) == before.devices.map(\.id))
        #expect(loaded.devices.map(\.name) == ["Test iPhone"])
        await second.startIfEnabled()
        #expect(await second.status().listening)
        let client = try await connectedClient(fixture, result)
        client.cancel()
        await second.shutdown()
    }

    @Test func resetReplacesTheKeyAndDropsDevices() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let result = try await pair(service)
        let client = try await connectedClient(fixture, result)
        let before = await service.status()
        let after = try await service.resetAccess()
        #expect(after.keyFingerprint != before.keyFingerprint)
        #expect(after.devices.isEmpty && after.listening && after.enabled)
        #expect(try await client.nextEvent() == .accessRevoked)
        try await client.expectClosed()
        let stale = RemoteTestClient(port: fixture.port, key: result.remoteAccessKey)
        await #expect(throws: RemoteTransportError.self) { try await stale.connect(timeout: 5) }
        let fresh = RemoteTestClient(port: fixture.port, key: try fixture.key())
        try await fresh.connect()
        #expect(try await fresh.request(hello(result)).error?.code == "unauthorized")
        await service.shutdown()
    }

    @Test func pairingExpiresAfterItsTimeoutOrWhenCancelled() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service(pairingTimeout: 0.5)
        _ = try await service.setEnabled(true, port: fixture.port)
        var status = try await service.beginPairing()
        let pairing = try #require(status.pairing)
        #expect(pairing.port == fixture.port + 1)
        #expect(pairing.code.count == 12 && PairingCode(pairing.code) != nil)
        #expect(pairing.expiresAt.timeIntervalSinceNow < 0.6)
        try await eventually { await service.status().pairing == nil }
        let code = try #require(PairingCode(pairing.code))
        let late = RemoteTestClient(port: pairing.port, key: code.derivedKey)
        await #expect(throws: (any Error).self) { try await late.connect(timeout: 3) }
        status = try await service.beginPairing()
        #expect(status.pairing != nil && status.pairing?.code != pairing.code)
        status = await service.cancelPairing()
        #expect(status.pairing == nil)
        await service.shutdown()
    }

    @Test func pairingRejectsWrongCodesAndStopsAfterRepeatedFailures() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let service = fixture.service()
        _ = try await service.setEnabled(true, port: fixture.port)
        let status = try await service.beginPairing()
        let pairing = try #require(status.pairing)
        for _ in 0..<RemoteAccessService.pairingFailureLimit {
            let wrong = RemoteTestClient(port: pairing.port, key: PairingCode.generate().derivedKey)
            await #expect(throws: RemoteTransportError.self) { try await wrong.connect(timeout: 5) }
        }
        try await eventually { await service.status().pairing == nil }
        #expect(await service.status().devices.isEmpty)
        await service.shutdown()
    }

    @Test func attachedTerminalStreamsOutputAndAcceptsInputOverTheLAN() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        try Data("READY-MARKER".utf8).write(to: fixture.path("unicode-output"))
        let session = try await fixture.runtime.launch(fixture.request)
        try await fixture.wait { try await fixture.runtime.terminals.capture(sessionID: session.id, lines: 100).screen.contains("READY-MARKER") }
        let port = Int.random(in: 20000...60000)
        let service = RemoteAccessService(root: fixture.root, runtime: fixture.runtime, hostName: "Test Mac")
        _ = try await service.setEnabled(true, port: port)
        let result = try await pair(service)
        let client = RemoteTestClient(port: port, key: result.remoteAccessKey)
        try await client.connect()
        guard case .hostInfo? = try await client.request(hello(result)).result else { Issue.record("hello failed"); return }

        let attach = try await client.request(.attachTerminal(AttachTerminalRequest(sessionID: session.id, cols: 100, rows: 30)))
        guard case .attachment(let info)? = attach.result else { Issue.record("expected attachment, got \(attach)"); return }
        #expect(info.sessionID == session.id && info.cols == 100 && info.rows == 30)
        #expect(info.generation == (await fixture.runtime.terminals.currentGeneration(sessionID: session.id)))
        // No output frame may overtake the attach response.
        #expect(client.skipped.isEmpty)

        var output = Data(), sequences: [UInt64] = []
        while !String(decoding: output, as: UTF8.self).contains("READY-MARKER") {
            let frame = try await client.nextFrame(timeout: 20)
            guard frame.type == .output else { continue }
            let payload = try TerminalFramePayload(decoding: frame.payload)
            #expect(payload.generation == info.generation)
            sequences.append(payload.sequence)
            output.append(payload.bytes)
        }
        #expect(sequences == Array(1...UInt64(sequences.count)))

        // A second client cannot take the terminal without asking for control.
        let other = RemoteTestClient(port: port, key: result.remoteAccessKey)
        try await other.connect()
        _ = try await other.request(hello(result))
        let busy = try await other.request(.attachTerminal(AttachTerminalRequest(sessionID: session.id, cols: 80, rows: 24)))
        #expect(busy.error?.code == "terminal_busy")
        other.cancel()

        try await client.send(RemoteFrame(type: .input, payload: TerminalFramePayload(generation: info.generation, sequence: 1, bytes: Data("typed-over-lan".utf8)).encoded()))
        try await fixture.wait { try await fixture.runtime.terminals.capture(sessionID: session.id, lines: 100).screen.contains("typed-over-lan") }
        while !String(decoding: output, as: UTF8.self).contains("typed-over-lan") {
            let frame = try await client.nextFrame(timeout: 20)
            guard frame.type == .output else { continue }
            output.append(try TerminalFramePayload(decoding: frame.payload).bytes)
        }
        #expect(try await client.request(.terminalResize(TerminalResizeRequest(generation: info.generation, cols: 1000, rows: 1))).result == .ack)
        #expect(try await client.request(.detachTerminal(DetachTerminalRequest(generation: info.generation))).result == .ack)
        #expect(await fixture.runtime.terminals.currentGeneration(sessionID: session.id) == nil)
        var ended: RemoteEvent?
        for _ in 0..<20 {
            let frame = try await client.nextFrame()
            if frame.type == .event { ended = try RemoteJSON.decode(RemoteEvent.self, from: frame.payload); break }
        }
        #expect(ended == .attachmentEnded(generation: info.generation, reason: .clientDetached, message: nil))
        // Input for the detached generation is answered with a single revocation event.
        try await client.send(RemoteFrame(type: .input, payload: TerminalFramePayload(generation: info.generation, sequence: 2, bytes: Data("late".utf8)).encoded()))
        try await client.send(RemoteFrame(type: .ping, payload: Data()))
        #expect(try await client.nextFrame().type == .pong)

        // Closing the connection detaches whatever it still controlled.
        let second = try await client.request(.attachTerminal(AttachTerminalRequest(sessionID: session.id, cols: 90, rows: 25)))
        guard case .attachment(let reattached)? = second.result else { Issue.record("expected reattachment, got \(second)"); return }
        #expect(reattached.generation > info.generation)
        client.cancel()
        try await fixture.wait { await fixture.runtime.terminals.currentGeneration(sessionID: session.id) == nil }
        await service.shutdown()
        _ = try await fixture.stop()
    }
}
