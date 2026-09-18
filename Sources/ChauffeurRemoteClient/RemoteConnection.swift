import Foundation
import ChauffeurRemoteProtocol

/// One authenticated connection to a Mac runtime: frames the wire, correlates requests with
/// responses, and fans out lifecycle events. Terminal output is delivered through a single
/// handler (see `setTerminalOutputHandler`) so exactly one `RemoteSessionController` owns it.
public actor RemoteConnection {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case ready(HostInfo)
        case failed(RemoteClientError)
        case closed
    }

    public private(set) var state: State = .idle

    private let transport: any RemoteTransport
    private let requestTimeout: Duration
    private let stateBroadcaster = Broadcaster<State>()
    private let eventBroadcaster = Broadcaster<RemoteEvent>()
    private var terminalOutputHandler: (@Sendable (TerminalFramePayload) -> Void)?
    private var pending: [UUID: PendingRequest] = [:]
    private var readTask: Task<Void, Never>?
    private var decoder = RemoteFrameDecoder()
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var transportIsReady = false
    private var pendingPings: [Data: CheckedContinuation<Bool, Never>] = [:]
    private var keepaliveTask: Task<Void, Never>?
    private let keepaliveInterval: Duration?
    private let keepaliveTimeout: Duration

    private struct PendingRequest {
        var continuation: CheckedContinuation<RemoteResponse, any Error>
        var timeout: Task<Void, Never>
    }

    /// `keepaliveInterval` nil disables the periodic ping. A host that misses a pong within
    /// `keepaliveTimeout` fails the connection with `.timeout`, which is how a socket killed while
    /// the app was suspended gets noticed instead of every later request timing out.
    public init(transport: any RemoteTransport, requestTimeout: Duration = .seconds(15),
                keepaliveInterval: Duration? = .seconds(10), keepaliveTimeout: Duration = .seconds(8)) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveTimeout = keepaliveTimeout
    }

    // MARK: Liveness

    /// Sends a ping and waits for its pong. False when the connection is not ready, the send
    /// fails, or the host stays silent past `timeout`.
    public func probe(timeout: Duration = .seconds(3)) async -> Bool {
        guard case .ready = state else { return false }
        var payload = Data(count: 16)
        payload.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8.random(in: .min ... .max) }
        }
        let answered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingPings[payload] = continuation
            Task {
                do {
                    try await self.send(RemoteFrame(type: .ping, payload: payload))
                } catch {
                    self.resolvePing(payload, answered: false)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.resolvePing(payload, answered: false)
            }
        }
        return answered
    }

    private func resolvePing(_ payload: Data, answered: Bool) {
        guard let continuation = pendingPings.removeValue(forKey: payload) else { return }
        continuation.resume(returning: answered)
    }

    private func startKeepalive() {
        guard let interval = keepaliveInterval else { return }
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                guard case .ready = await self.state else { return }
                if await !self.probe(timeout: self.keepaliveTimeout) {
                    await self.keepaliveMissed()
                    return
                }
            }
        }
    }

    private func keepaliveMissed() {
        guard case .ready = state else { return }
        fail(with: .timeout)
        transport.cancel()
    }

    // MARK: Observation

    /// A fresh stream per call. It starts with the current state, then every change. Each stream
    /// belongs to one consumer; drop it to unsubscribe.
    public func stateChanges() -> AsyncStream<State> {
        stateBroadcaster.subscribe(initial: state)
    }

    /// Decoded `.event` frames. A fresh stream per call; each belongs to one consumer.
    public func events() -> AsyncStream<RemoteEvent> {
        eventBroadcaster.subscribe()
    }

    /// Decoded `.output` frames go to this single handler, in wire order, on the connection's
    /// executor. Pass `nil` to detach the current handler.
    public func setTerminalOutputHandler(_ handler: (@Sendable (TerminalFramePayload) -> Void)?) {
        terminalOutputHandler = handler
    }

    // MARK: Lifecycle

    /// Starts the transport and waits for it to become ready. Used by `connect(hello:)`, and on
    /// its own by pairing, whose first request is `pair` rather than `hello`.
    public func open() async throws {
        switch state {
        case .idle:
            break
        case .connecting, .ready:
            return
        case .failed(let error):
            throw error
        case .closed:
            throw RemoteClientError.disconnected
        }
        setState(.connecting)
        readTask = Task { await self.runReadLoop() }
        transport.start()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if transportIsReady {
                continuation.resume()
            } else if case .failed(let error) = state {
                continuation.resume(throwing: error)
            } else if case .closed = state {
                continuation.resume(throwing: RemoteClientError.disconnected)
            } else {
                readyContinuation = continuation
            }
        }
    }

    /// Opens the transport, sends `hello`, and verifies the protocol version.
    public func connect(hello: HelloRequest) async throws -> HostInfo {
        try await open()
        let response: RemoteResponse
        do {
            response = try await sendRequest(.hello(hello))
        } catch let error as RemoteClientError {
            fail(with: error)
            throw error
        }

        if let error = response.error {
            let mapped = Self.mapHelloError(error)
            fail(with: mapped)
            throw mapped
        }
        guard case .hostInfo(let info)? = response.result else {
            let error = RemoteClientError.invalidResponse("hello returned \(response.result?.kind ?? "nothing")")
            fail(with: error)
            throw error
        }
        guard info.protocolVersion == RemoteProtocol.version else {
            let error = RemoteClientError.protocolMismatch(hostVersion: info.protocolVersion, clientVersion: RemoteProtocol.version)
            fail(with: error)
            throw error
        }
        setState(.ready(info))
        startKeepalive()
        return info
    }

    public func close() {
        finish(with: .closed)
        transport.cancel()
    }

    // MARK: Requests

    /// Sends one operation and returns its result, or throws `.remote` for a host error.
    public func request(_ operation: RemoteOperation) async throws -> RemoteResult {
        let response = try await sendRequest(operation)
        if let error = response.error {
            throw RemoteClientError.remote(error)
        }
        guard let result = response.result else {
            throw RemoteClientError.invalidResponse("Response has neither result nor error")
        }
        return result
    }

    /// Sends raw terminal bytes for `generation`, split at the protocol's chunk limit.
    public func sendTerminalInput(generation: UInt64, bytes: Data) async throws {
        try ensureOpen()
        var offset = bytes.startIndex
        repeat {
            let end = min(offset + RemoteFraming.maxTerminalChunkBytes, bytes.endIndex)
            let payload = TerminalFramePayload(generation: generation, sequence: 0, bytes: Data(bytes[offset..<end]))
            try await send(RemoteFrame(type: .input, payload: payload.encoded()))
            offset = end
        } while offset < bytes.endIndex
    }

    private func sendRequest(_ operation: RemoteOperation) async throws -> RemoteResponse {
        try ensureOpen()
        let request = RemoteRequest(operation: operation)
        let id = request.id
        let payload: Data
        do {
            payload = try RemoteJSON.encode(request)
        } catch {
            throw RemoteClientError.invalidResponse("Could not encode request: \(error)")
        }
        let frame = RemoteFrame(type: .request, payload: payload)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteResponse, any Error>) in
            let timeout = Task { [requestTimeout] in
                try? await Task.sleep(for: requestTimeout)
                guard !Task.isCancelled else { return }
                self.expire(id)
            }
            pending[id] = PendingRequest(continuation: continuation, timeout: timeout)
            Task {
                do {
                    try await self.send(frame)
                } catch {
                    self.resolve(id, with: .failure(Self.mapTransportError(error)))
                }
            }
        }
    }

    private func send(_ frame: RemoteFrame) async throws {
        do {
            try await transport.send(RemoteFraming.encode(frame))
        } catch {
            throw Self.mapTransportError(error)
        }
    }

    private func ensureOpen() throws {
        switch state {
        case .idle:
            throw RemoteClientError.disconnected
        case .failed(let error):
            throw error
        case .closed:
            throw RemoteClientError.disconnected
        case .connecting, .ready:
            break
        }
    }

    private func expire(_ id: UUID) {
        resolve(id, with: .failure(RemoteClientError.timeout))
    }

    private func resolve(_ id: UUID, with result: Result<RemoteResponse, any Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.continuation.resume(with: result)
    }

    // MARK: Read loop

    private func runReadLoop() async {
        for await event in transport.events {
            handleTransportEvent(event)
            if isTerminal(state) { break }
        }
        finish(with: .closed)
    }

    private func handleTransportEvent(_ event: RemoteTransportEvent) {
        switch event {
        case .ready:
            transportIsReady = true
            readyContinuation?.resume()
            readyContinuation = nil
        case .bytes(let data):
            let frames: [RemoteFrame]
            do {
                frames = try decoder.append(data)
            } catch {
                fail(with: .framing(String(describing: error)))
                transport.cancel()
                return
            }
            for frame in frames {
                handleFrame(frame)
                if isTerminal(state) { return }
            }
        case .failed(let error):
            fail(with: error)
        case .closed:
            finish(with: .closed)
        }
    }

    private func handleFrame(_ frame: RemoteFrame) {
        switch frame.type {
        case .response:
            guard let response = try? RemoteJSON.decode(RemoteResponse.self, from: frame.payload) else {
                fail(with: .invalidResponse("Undecodable response frame"))
                transport.cancel()
                return
            }
            resolve(response.id, with: .success(response))
        case .event:
            // Unknown event kinds from a newer host are ignored rather than fatal.
            if let event = try? RemoteJSON.decode(RemoteEvent.self, from: frame.payload) {
                eventBroadcaster.send(event)
            }
        case .output:
            guard let payload = try? TerminalFramePayload(decoding: frame.payload) else {
                fail(with: .framing("Truncated terminal output frame"))
                transport.cancel()
                return
            }
            terminalOutputHandler?(payload)
        case .ping:
            Task {
                try? await self.send(RemoteFrame(type: .pong, payload: frame.payload))
            }
        case .pong:
            resolvePing(frame.payload, answered: true)
        case .input, .request:
            break
        }
    }

    // MARK: State transitions

    private func setState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        stateBroadcaster.send(newState)
    }

    private func isTerminal(_ state: State) -> Bool {
        switch state {
        case .failed, .closed: return true
        case .idle, .connecting, .ready: return false
        }
    }

    private func fail(with error: RemoteClientError) {
        finish(with: .failed(error))
    }

    /// Moves to a terminal state once: fails every pending request with `.disconnected`,
    /// wakes a pending `open()`, and finishes all subscriber streams.
    private func finish(with terminalState: State) {
        guard !isTerminal(state) else { return }
        setState(terminalState)
        keepaliveTask?.cancel()
        keepaliveTask = nil
        for payload in Array(pendingPings.keys) { resolvePing(payload, answered: false) }

        let failure: RemoteClientError
        if case .failed(let error) = terminalState {
            failure = error
        } else {
            failure = .disconnected
        }
        readyContinuation?.resume(throwing: failure)
        readyContinuation = nil

        let entries = pending
        pending.removeAll()
        for entry in entries.values {
            entry.timeout.cancel()
            entry.continuation.resume(throwing: RemoteClientError.disconnected)
        }

        terminalOutputHandler = nil
        eventBroadcaster.finish()
        stateBroadcaster.finish()
    }

    // MARK: Error mapping

    private static func mapTransportError(_ error: any Error) -> RemoteClientError {
        if let clientError = error as? RemoteClientError {
            return clientError
        }
        return .network(String(describing: error))
    }

    static func mapHelloError(_ error: RemoteError) -> RemoteClientError {
        switch error.code {
        case "protocol_mismatch":
            return .protocolMismatch(hostVersion: firstInteger(in: error.message) ?? 0, clientVersion: RemoteProtocol.version)
        case "unauthorized", "device_revoked", "unknown_device":
            return .unauthorized(error.message)
        default:
            return .remote(error)
        }
    }

    private static func firstInteger(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}

/// Fan-out of one value stream to any number of independent `AsyncStream` consumers. Each
/// subscriber gets its own unbounded buffer; dropping a stream unsubscribes it.
final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var isFinished = false

    func subscribe(initial: Element? = nil) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .unbounded)
        let id = UUID()
        let accepted: Bool = lock.withLock {
            guard !isFinished else { return false }
            continuations[id] = continuation
            return true
        }
        if let initial {
            continuation.yield(initial)
        }
        guard accepted else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func send(_ element: Element) {
        let targets = lock.withLock { Array(continuations.values) }
        for target in targets {
            target.yield(element)
        }
    }

    func finish() {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            isFinished = true
            let values = Array(continuations.values)
            continuations.removeAll()
            return values
        }
        for target in targets {
            target.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.withLock { _ = continuations.removeValue(forKey: id) }
    }
}
