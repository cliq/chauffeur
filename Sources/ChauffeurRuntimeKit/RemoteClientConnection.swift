import Foundation
import ChauffeurCore
import ChauffeurRemoteProtocol

/// One authenticated (or not yet authenticated) iPhone connection on the main
/// remote port. Owns the frame decoder, the terminal attachments it opened and
/// the serialized send path every response, event and output frame goes through.
actor RemoteClientConnection: RemoteConnectionHandle {
    nonisolated let id = UUID()
    static let handshakeTimeout: TimeInterval = 10
    static let readChunk = 64 * 1024

    private let transport: RemoteTransport
    private let service: RemoteAccessService
    private let runtime: RuntimeCoordinator
    private let dispatcher: any RemoteOperationDispatching
    private var decoder = RemoteFrameDecoder()
    private(set) var deviceID: UUID?
    /// What the client advertised in its hello; older builds decode fewer session kinds.
    private var clientCapabilities: [String] = []
    /// sessionID → generation of the attachment this connection controls.
    private var attachments: [UUID: AttachmentGeneration] = [:]
    private var sinks: [AttachmentGeneration: RemoteFrameSink] = [:]
    /// Generations whose loss was already reported; later input is dropped silently.
    private var endedGenerations = Set<AttachmentGeneration>()
    private var closed = false
    private var handshakeDeadline: Task<Void, Never>?

    init(transport: RemoteTransport, service: RemoteAccessService, runtime: RuntimeCoordinator, dispatcher: any RemoteOperationDispatching) {
        self.transport = transport
        self.service = service
        self.runtime = runtime
        self.dispatcher = dispatcher
    }

    nonisolated var remoteAddress: String { transport.remoteAddress }

    // MARK: Lifecycle

    /// Serves the connection until the peer disconnects, a protocol violation
    /// occurs or the connection is closed from this side.
    func run() async {
        handshakeDeadline = Task { [transport] in
            try? await Task.sleep(for: .seconds(Self.handshakeTimeout))
            guard !Task.isCancelled else { return }
            // Neither TLS nor hello finished in time; the receive below fails.
            transport.cancel()
        }
        do {
            try await transport.start(timeout: Self.handshakeTimeout)
            while !closed {
                guard let chunk = try await transport.receive(maximumLength: Self.readChunk) else { break }
                if chunk.isEmpty { continue }
                let frames = try decoder.append(chunk)
                for frame in frames { try await handle(frame) }
            }
        } catch {
            // Peer gone, TLS rejected, decoder poisoned or a violation: all end the connection.
        }
        await close()
    }

    /// Detaches every terminal this connection controls and cancels the transport.
    func close() async {
        guard !closed else { return }
        closed = true
        handshakeDeadline?.cancel()
        transport.cancel()
        let owned = attachments
        attachments = [:]
        sinks = [:]
        for (sessionID, generation) in owned {
            await runtime.terminals.detach(sessionID: sessionID, generation: generation)
        }
    }

    /// Tells the peer its device was unpaired, then closes.
    func revoke() async {
        guard !closed else { return }
        let watchdog = Task { [transport] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            transport.cancel()
        }
        await sendEvent(.accessRevoked)
        watchdog.cancel()
        await close()
    }

    // MARK: Sending

    func send(_ data: Data) async throws {
        guard !closed else { throw RemoteTransportError.closed }
        try await transport.send(data)
    }

    func sendEvent(_ event: RemoteEvent) async {
        guard let payload = try? RemoteJSON.encode(event) else { return }
        try? await send(RemoteFraming.encode(RemoteFrame(type: .event, payload: payload)))
    }

    private func send(response: RemoteResponse) async throws {
        try await send(RemoteFraming.encode(RemoteFrame(type: .response, payload: try RemoteJSON.encode(response))))
    }

    // MARK: Frames

    private func handle(_ frame: RemoteFrame) async throws {
        switch frame.type {
        case .request:
            let request: RemoteRequest
            do { request = try RemoteJSON.decode(RemoteRequest.self, from: frame.payload) }
            catch { throw RemoteProtocolViolation.malformedRequest }
            guard deviceID != nil else { try await hello(request); return }
            Task { await self.respond(to: request) }
        case .input:
            guard deviceID != nil else { throw RemoteProtocolViolation.helloRequired }
            let payload: TerminalFramePayload
            do { payload = try TerminalFramePayload(decoding: frame.payload) }
            catch { throw RemoteProtocolViolation.malformedInput }
            await input(payload)
        case .ping:
            try await send(RemoteFraming.encode(RemoteFrame(type: .pong, payload: frame.payload)))
        case .pong, .response, .event, .output:
            break
        }
    }

    /// The first frame must be `hello`; anything else, a protocol mismatch or
    /// an unknown device ends the connection after a single error response.
    private func hello(_ request: RemoteRequest) async throws {
        guard case .hello(let hello) = request.operation else {
            try? await send(response: RemoteResponse(id: request.id, error: RemoteError(code: "hello_required", message: "The first request must be hello")))
            throw RemoteProtocolViolation.helloRequired
        }
        switch await service.authenticate(hello, connectionID: id, remoteAddress: remoteAddress) {
        case .failure(let error):
            try? await send(response: RemoteResponse(id: request.id, error: error))
            throw RemoteProtocolViolation.unauthorized
        case .success(let info):
            deviceID = hello.deviceID
            clientCapabilities = hello.capabilities
            handshakeDeadline?.cancel(); handshakeDeadline = nil
            try await send(response: RemoteResponse(id: request.id, result: .hostInfo(info)))
        }
    }

    private func respond(to request: RemoteRequest) async {
        guard let deviceID else { return }
        let result: Result<RemoteResult, RemoteError>
        switch request.operation {
        case .hello:
            result = .failure(RemoteError(code: "invalid_state", message: "This connection is already authenticated"))
        case .pair:
            result = .failure(RemoteError(code: "unsupported_operation", message: "Pairing happens on the pairing port"))
        case .attachTerminal(let attach):
            await self.attach(attach, requestID: request.id)
            return
        case .terminalResize(let resize):
            result = await self.resize(resize)
        case .detachTerminal(let detach):
            result = await self.detach(detach)
        case .listInventory, .getSessionProgress, .previewWorktreeDestination, .launch, .getOperationStatus:
            result = await dispatcher.handle(request.operation, deviceID: deviceID)
        }
        let capabilities = clientCapabilities
        let compatible = result.map { value -> RemoteResult in
            if case .inventory(let inventory) = value { return .inventory(inventory.compatible(withClientCapabilities: capabilities)) }
            return value
        }
        let response: RemoteResponse
        switch compatible {
        case .success(let value): response = RemoteResponse(id: request.id, result: value)
        case .failure(let error): response = RemoteResponse(id: request.id, error: error)
        }
        try? await send(response: response)
    }

    // MARK: Terminals

    /// The attach response is written before any output frame: the sink holds
    /// output until the response left this actor's send path.
    private func attach(_ request: AttachTerminalRequest, requestID: UUID) async {
        let sink = RemoteFrameSink(handle: self) { [weak self] generation in
            guard let self else { return }
            Task { await self.sinkClosed(generation) }
        }
        let generation: AttachmentGeneration
        do {
            generation = try await runtime.attach(sessionID: request.sessionID, sink: sink, cols: request.cols, rows: request.rows, takeControl: request.takeControl)
        } catch {
            try? await send(response: RemoteResponse(id: requestID, error: RemoteError.from(error)))
            return
        }
        guard !closed else {
            await runtime.terminals.detach(sessionID: request.sessionID, generation: generation)
            sink.releaseOutput(generation: generation)
            return
        }
        attachments[request.sessionID] = generation
        sinks[generation] = sink
        defer { sink.releaseOutput(generation: generation) }
        do {
            try await send(response: RemoteResponse(id: requestID, result: .attachment(AttachmentInfo(generation: generation, sessionID: request.sessionID, cols: request.cols, rows: request.rows))))
        } catch {
            if attachments[request.sessionID] == generation { attachments.removeValue(forKey: request.sessionID) }
            sinks.removeValue(forKey: generation)
            await runtime.terminals.detach(sessionID: request.sessionID, generation: generation)
        }
    }

    private func resize(_ request: TerminalResizeRequest) async -> Result<RemoteResult, RemoteError> {
        guard let sessionID = sessionID(for: request.generation) else {
            return .failure(RemoteError(code: "attachment_lost", message: "Terminal is not attached"))
        }
        let cols = min(max(request.cols, 2), 500), rows = min(max(request.rows, 2), 300)
        do {
            try await runtime.terminals.resize(sessionID: sessionID, generation: request.generation, cols: cols, rows: rows)
            return .success(.ack)
        } catch {
            return .failure(RemoteError.from(error))
        }
    }

    /// Detaching an unknown or stale generation is a no-op by design.
    private func detach(_ request: DetachTerminalRequest) async -> Result<RemoteResult, RemoteError> {
        if let sessionID = sessionID(for: request.generation) {
            attachments.removeValue(forKey: sessionID)
            sinks.removeValue(forKey: request.generation)
            await runtime.terminals.detach(sessionID: sessionID, generation: request.generation)
        }
        return .success(.ack)
    }

    private func input(_ payload: TerminalFramePayload) async {
        guard !endedGenerations.contains(payload.generation), let sessionID = sessionID(for: payload.generation) else { return }
        do {
            try await runtime.terminals.input(sessionID: sessionID, generation: payload.generation, bytes: payload.bytes)
        } catch {
            endedGenerations.insert(payload.generation)
            if attachments[sessionID] == payload.generation { attachments.removeValue(forKey: sessionID) }
            sinks.removeValue(forKey: payload.generation)
            let message = (error as? ChauffeurError)?.message ?? "Terminal input was rejected"
            await sendEvent(.attachmentEnded(generation: payload.generation, reason: .revoked, message: message))
        }
    }

    /// The runtime closed a sink (control lost, session ended, slow consumer).
    private func sinkClosed(_ generation: AttachmentGeneration) {
        sinks.removeValue(forKey: generation)
        endedGenerations.insert(generation)
        if let sessionID = sessionID(for: generation) { attachments.removeValue(forKey: sessionID) }
    }

    private func sessionID(for generation: AttachmentGeneration) -> UUID? {
        attachments.first { $0.value == generation }?.key
    }
}

enum RemoteProtocolViolation: Error {
    case malformedRequest
    case malformedInput
    case helloRequired
    case unauthorized
}

extension RemoteError {
    /// Runtime errors keep their code so the phone can react to `terminal_busy`,
    /// `not_live` and friends the way the desktop does.
    static func from(_ error: Error) -> RemoteError {
        if let remote = error as? RemoteError { return remote }
        if let failure = error as? ChauffeurError { return RemoteError(code: failure.code, message: failure.errorDescription ?? failure.message) }
        return RemoteError(code: "operation_failed", message: error.localizedDescription)
    }
}
