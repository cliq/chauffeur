import Foundation
import Network

/// Resume-once guard for bridging state callbacks into a continuation.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}

/// Wraps an NWConnection with async frame send/receive. `@unchecked Sendable` because NWConnection is
/// internally thread-safe and we only touch it from its dispatch queue or via its own API.
final class Peer: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let label: String
    private let lock = NSLock()
    private var _framesReceived = 0
    private var _lastState: NWConnection.State = .setup

    var framesReceived: Int { lock.withLock { _framesReceived } }
    var lastState: NWConnection.State { lock.withLock { _lastState } }

    init(connection: NWConnection, label: String) {
        self.connection = connection
        self.label = label
        self.queue = DispatchQueue(label: "psk-spike.\(label)")
    }

    /// Starts the connection and waits for `.ready`. Throws on `.failed`, `.waiting` (TLS errors surface here too) or timeout.
    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once(cont)
            connection.stateUpdateHandler = { [self] state in
                lock.withLock { _lastState = state }
                log("[\(label)] state -> \(describe(state))")
                switch state {
                case .ready: once.resume(.success(()))
                case .failed(let e): once.resume(.failure(SpikeError.connectionFailed(e)))
                case .waiting(let e): once.resume(.failure(SpikeError.connectionWaiting(e)))
                case .cancelled: once.resume(.failure(SpikeError.cancelled))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(SpikeError.timeout("\(self.label) did not become ready in \(timeout)s")))
            }
        }
    }

    func cancel() { connection.cancel() }

    // MARK: Sending (waits for .contentProcessed before returning -> natural backpressure)

    func send(type: FrameType, payload: Data) async throws {
        var frame = FrameHeader(type: type.rawValue, payloadLength: UInt32(payload.count)).encoded()
        frame.append(payload)
        try await sendRaw(frame)
    }

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    // MARK: Receiving (exact-length reads: header, then payload)

    func receiveExactly(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                guard let content, content.count == count else {
                    cont.resume(throwing: SpikeError.shortRead(expected: count, got: content?.count ?? 0))
                    return
                }
                _ = isComplete
                cont.resume(returning: content)
            }
        }
    }

    func receiveFrame() async throws -> (header: FrameHeader, payload: Data) {
        let header = try FrameHeader(decoding: try await receiveExactly(FrameHeader.size))
        let payload = try await receiveExactly(Int(header.payloadLength))
        lock.withLock { _framesReceived += 1 }
        return (header, payload)
    }
}

/// Listener wrapper that hands out accepted connections as `Peer`s through an async stream.
final class Server: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "psk-spike.listener")
    private let stream: AsyncStream<Peer>
    private let streamContinuation: AsyncStream<Peer>.Continuation
    private var iterator: AsyncStream<Peer>.Iterator
    private var accepted = 0

    init(psk: Data, flavor: TLSFlavor, host: String = "127.0.0.1") throws {
        let params = makeParameters(psk: psk, flavor: flavor)
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        listener = try NWListener(using: params)
        (stream, streamContinuation) = AsyncStream.makeStream(of: Peer.self)
        iterator = stream.makeAsyncIterator()
    }

    /// Starts listening and returns the ephemeral port.
    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            accepted += 1
            let peer = Peer(connection: connection, label: "server-conn\(accepted)")
            log("[listener] accepted connection from \(connection.endpoint)")
            streamContinuation.yield(peer)
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = Once(cont)
            listener.stateUpdateHandler = { [self] state in
                log("[listener] state -> \(describe(state))")
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { once.resume(.success(port)) }
                    else { once.resume(.failure(SpikeError.protocolViolation("listener ready without port"))) }
                case .failed(let e): once.resume(.failure(SpikeError.connectionFailed(e)))
                case .waiting(let e): once.resume(.failure(SpikeError.connectionWaiting(e)))
                case .cancelled: once.resume(.failure(SpikeError.cancelled))
                default: break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(SpikeError.timeout("listener did not become ready")))
            }
        }
    }

    /// Next accepted (not yet started) connection.
    func nextConnection() async -> Peer? {
        await iterator.next()
    }

    func cancel() { listener.cancel() }
}

// MARK: Helpers

func describe(_ state: NWConnection.State) -> String {
    switch state {
    case .setup: return "setup"
    case .preparing: return "preparing"
    case .waiting(let e): return "waiting(\(e))"
    case .ready: return "ready"
    case .failed(let e): return "failed(\(e))"
    case .cancelled: return "cancelled"
    @unknown default: return "unknown"
    }
}

func describe(_ state: NWListener.State) -> String {
    switch state {
    case .setup: return "setup"
    case .waiting(let e): return "waiting(\(e))"
    case .ready: return "ready"
    case .failed(let e): return "failed(\(e))"
    case .cancelled: return "cancelled"
    @unknown default: return "unknown"
    }
}

let logLock = NSLock()
func log(_ message: String) {
    logLock.withLock {
        print(message)
        fflush(stdout)
    }
}

/// Races `operation` against a deadline. Note the continuation-based operations are not cancellable,
/// so callers must cancel the underlying connection when a timeout fires.
func withTimeout<T: Sendable>(_ seconds: Double, _ what: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SpikeError.timeout(what)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
