import Foundation
import Testing
import ChauffeurRemoteProtocol
@testable import ChauffeurRemoteClient

/// The Mac side of an `InMemoryTransportPair`: decodes frames, records what it saw, answers
/// requests through a scripted responder, and can push events, output frames, pings, or raw bytes.
final class FakeHost: @unchecked Sendable {
    static let hostID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let attachmentGeneration: UInt64 = 7
    static let mainPort = 51847

    let transport: InMemoryTransport

    private let lock = NSLock()
    private var _requests: [RemoteRequest] = []
    private var _inputFrames: [TerminalFramePayload] = []
    private var _pongs: [Data] = []
    private var _answersPings = true
    private var _sendByteByByte = false
    private var _responder: @Sendable (RemoteRequest) -> RemoteResponse? = FakeHost.defaultResponse(for:)
    private var task: Task<Void, Never>?

    init(transport: InMemoryTransport) {
        self.transport = transport
    }

    var requests: [RemoteRequest] { lock.withLock { _requests } }
    var inputFrames: [TerminalFramePayload] { lock.withLock { _inputFrames } }
    var pongs: [Data] { lock.withLock { _pongs } }
    /// Whether the fake answers client pings; false simulates a host that died silently.
    var answersPings: Bool {
        get { lock.withLock { _answersPings } }
        set { lock.withLock { _answersPings = newValue } }
    }

    func requests(ofKind kind: String) -> [RemoteRequest] {
        requests.filter { $0.operation.kind == kind }
    }

    /// Returning `nil` leaves the request unanswered (answer later with `respond`, or never).
    var responder: @Sendable (RemoteRequest) -> RemoteResponse? {
        get { lock.withLock { _responder } }
        set { lock.withLock { _responder = newValue } }
    }

    /// When true every frame is written one byte at a time to exercise reassembly.
    var sendByteByByte: Bool {
        get { lock.withLock { _sendByteByByte } }
        set { lock.withLock { _sendByteByByte = newValue } }
    }

    func start() {
        transport.start()
        task = Task.detached { [self] in
            var decoder = RemoteFrameDecoder()
            for await event in transport.events {
                switch event {
                case .ready:
                    continue
                case .bytes(let data):
                    guard let frames = try? decoder.append(data) else { return }
                    for frame in frames {
                        await handle(frame)
                    }
                case .failed, .closed:
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        transport.close()
    }

    // MARK: Pushing

    func respond(to id: UUID, result: RemoteResult) async {
        await send(.response, payload: try! RemoteJSON.encode(RemoteResponse(id: id, result: result)))
    }

    func respond(to id: UUID, error: RemoteError) async {
        await send(.response, payload: try! RemoteJSON.encode(RemoteResponse(id: id, error: error)))
    }

    func pushEvent(_ event: RemoteEvent) async {
        await send(.event, payload: try! RemoteJSON.encode(event))
    }

    func pushOutput(generation: UInt64 = FakeHost.attachmentGeneration, sequence: UInt64, _ text: String) async {
        let payload = TerminalFramePayload(generation: generation, sequence: sequence, bytes: Data(text.utf8))
        await send(.output, payload: payload.encoded())
    }

    func ping(_ payload: Data = Data()) async {
        await send(.ping, payload: payload)
    }

    func sendRaw(_ data: Data) async {
        try? await transport.send(data)
    }

    // MARK: Internals

    private func handle(_ frame: RemoteFrame) async {
        switch frame.type {
        case .request:
            guard let request = try? RemoteJSON.decode(RemoteRequest.self, from: frame.payload) else { return }
            let responder: @Sendable (RemoteRequest) -> RemoteResponse? = lock.withLock {
                _requests.append(request)
                return _responder
            }
            if let response = responder(request) {
                await send(.response, payload: try! RemoteJSON.encode(response))
            }
        case .input:
            if let payload = try? TerminalFramePayload(decoding: frame.payload) {
                lock.withLock { _inputFrames.append(payload) }
            }
        case .pong:
            lock.withLock { _pongs.append(frame.payload) }
        case .ping:
            if lock.withLock({ _answersPings }) {
                await send(.pong, payload: frame.payload)
            }
        case .response, .event, .output:
            break
        }
    }

    private func send(_ type: RemoteFrameType, payload: Data) async {
        let encoded = RemoteFraming.encode(RemoteFrame(type: type, payload: payload))
        if sendByteByByte {
            for byte in encoded {
                try? await transport.send(Data([byte]))
            }
        } else {
            try? await transport.send(encoded)
        }
    }

    // MARK: Default script

    static func hostInfo(protocolVersion: Int = RemoteProtocol.version) -> HostInfo {
        HostInfo(
            hostID: hostID,
            hostName: "fake-mac",
            runtimeVersion: "1.0",
            build: "1",
            protocolVersion: protocolVersion,
            capabilities: RemoteProtocol.capabilities
        )
    }

    static func inventory(revision: UInt64 = 1) -> InventorySnapshot {
        InventorySnapshot(revision: revision, hostName: "fake-mac", generatedAt: Date(timeIntervalSince1970: 1_000))
    }

    @Sendable
    static func defaultResponse(for request: RemoteRequest) -> RemoteResponse? {
        switch request.operation {
        case .hello:
            return RemoteResponse(id: request.id, result: .hostInfo(hostInfo()))
        case .pair:
            let pairing = PairingResult(
                remoteAccessKey: Data(repeating: 0xAB, count: 32),
                deviceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                deviceToken: "token-123",
                mainPort: mainPort,
                hostID: hostID,
                hostName: "fake-mac"
            )
            return RemoteResponse(id: request.id, result: .pairing(pairing))
        case .getSessionProgress:
            return RemoteResponse(id: request.id, error: RemoteError(code: "progress_unavailable", message: "No progress panel"))
        case .listInventory:
            return RemoteResponse(id: request.id, result: .inventory(inventory()))
        case .previewWorktreeDestination(let preview):
            return RemoteResponse(id: request.id, result: .worktreeDestination(WorktreeDestinationPreview(path: "/tmp/worktrees/\(preview.branch)")))
        case .launch(let launch):
            let status = OperationStatus(operationKey: launch.operationKey, phase: .completed, sessionID: UUID(), updatedAt: Date())
            return RemoteResponse(id: request.id, result: .operation(status))
        case .getOperationStatus(let query):
            let status = OperationStatus(operationKey: query.operationKey, phase: .completed, sessionID: UUID(), updatedAt: Date())
            return RemoteResponse(id: request.id, result: .operation(status))
        case .attachTerminal(let attach):
            let info = AttachmentInfo(generation: attachmentGeneration, sessionID: attach.sessionID, cols: attach.cols, rows: attach.rows)
            return RemoteResponse(id: request.id, result: .attachment(info))
        case .terminalResize, .detachTerminal:
            return RemoteResponse(id: request.id, result: .ack)
        }
    }
}

// MARK: - Fixtures

enum Fixtures {
    static func hello() -> HelloRequest {
        HelloRequest(
            deviceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            deviceToken: "token-123",
            clientName: "Tests",
            clientVersion: "0",
            protocolVersion: RemoteProtocol.version,
            capabilities: RemoteProtocol.capabilities
        )
    }

    static func savedHost() -> SavedHost {
        SavedHost(
            hostID: FakeHost.hostID,
            name: "fake-mac",
            host: "192.168.1.10",
            port: FakeHost.mainPort,
            remoteAccessKey: Data(repeating: 0xAB, count: 32),
            deviceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            deviceToken: "token-123",
            pairedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    static func launchRequest(key: UUID = UUID()) -> LaunchOperationRequest {
        let launch = LaunchSpec(projectID: UUID(), folderID: UUID(), title: "Test")
        return LaunchOperationRequest(
            operationKey: key,
            fingerprint: LaunchOperationRequest.computeFingerprint(newWorktree: nil, launch: launch),
            launch: launch
        )
    }
}

/// Polls `condition` until it holds or `timeout` passes. Returns the final evaluation.
@MainActor
func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A mutable, lock-protected box for values written from non-main contexts.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
