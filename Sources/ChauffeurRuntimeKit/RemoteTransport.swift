import Foundation
import Network
import Security

/// Certificate-less TLS for the LAN link: TLS 1.2 with the RFC 5487 PSK suite,
/// the only pre-shared-key path Network.framework exposes. Both ends build the
/// same options; the phone's copy lives in the portable client module.
enum RemoteTLS {
    static let identity = "chauffeur-remote"

    static func parameters(psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        // tls_ciphersuite_t has no PSK cases; the SecureTransport constant is 0x00A8.
        let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(options, suite)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}

enum RemoteTransportError: Error, CustomStringConvertible {
    case timeout(String)
    case failed(NWError)
    case waiting(NWError)
    case cancelled
    case closed

    var description: String {
        switch self {
        case .timeout(let what): return "timeout: \(what)"
        case .failed(let error): return "connection failed: \(error)"
        case .waiting(let error): return "connection waiting: \(error)"
        case .cancelled: return "connection cancelled"
        case .closed: return "connection closed"
        }
    }
}

/// Resume-once guard for bridging state callbacks into a continuation.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Async send/receive over one `NWConnection`. `@unchecked Sendable` because
/// the connection is internally thread-safe and only driven through its API.
/// Sends are queued by Network.framework in call order, and each one returns
/// once the bytes were handed over, which is the backpressure sinks rely on.
final class RemoteTransport: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var state: NWConnection.State = .setup
    private var started = false

    init(connection: NWConnection, label: String) {
        self.connection = connection
        self.queue = DispatchQueue(label: "dev.chauffeur.remote.\(label)")
    }

    /// Numeric address of the peer, used as the rate-limit key.
    var remoteAddress: String {
        guard case .hostPort(let host, _) = connection.endpoint else { return String(describing: connection.endpoint) }
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        return text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
    }

    var currentState: NWConnection.State { lock.withLock { state } }

    private func claimStart() -> Bool {
        lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
    }

    /// Starts the connection and waits for `.ready`. A wrong pre-shared key
    /// surfaces as `.failed` on the accepting side and `.waiting` on the
    /// connecting side; both are terminal here and cancel the connection.
    func start(timeout: TimeInterval) async throws {
        guard claimStart() else { return }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(continuation)
                connection.stateUpdateHandler = { [self] state in
                    lock.withLock { self.state = state }
                    switch state {
                    case .ready: once.resume(.success(()))
                    case .failed(let error): once.resume(.failure(RemoteTransportError.failed(error)))
                    case .waiting(let error): once.resume(.failure(RemoteTransportError.waiting(error)))
                    case .cancelled: once.resume(.failure(RemoteTransportError.cancelled))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    once.resume(.failure(RemoteTransportError.timeout("TLS handshake did not finish in \(Int(timeout)) s")))
                }
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    func cancel() { connection.cancel() }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: RemoteTransportError.failed(error)) } else { continuation.resume() }
            })
        }
    }

    /// The next chunk of bytes, or nil once the peer closed its side.
    func receive(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { content, _, isComplete, error in
                if let error { continuation.resume(throwing: RemoteTransportError.failed(error)); return }
                if let content, !content.isEmpty { continuation.resume(returning: content); return }
                if isComplete { continuation.resume(returning: nil); return }
                continuation.resume(returning: Data())
            }
        }
    }
}

/// `NWListener` wrapper that reports accepted connections as transports.
final class RemoteListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let label: String
    private let lock = NSLock()
    private var accepted = 0
    private var failure: String?
    private let onConnection: @Sendable (RemoteTransport) -> Void

    init(psk: Data, port: Int, label: String, onConnection: @escaping @Sendable (RemoteTransport) -> Void) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { throw RemoteTransportError.timeout("invalid port") }
        listener = try NWListener(using: RemoteTLS.parameters(psk: psk), on: endpointPort)
        queue = DispatchQueue(label: "dev.chauffeur.remote.listener.\(label)")
        self.label = label
        self.onConnection = onConnection
    }

    /// A description of why the listener stopped after it became ready, if it did.
    var failureDescription: String? { lock.withLock { failure } }

    func start(timeout: TimeInterval = 5) async throws {
        listener.newConnectionHandler = { [self] connection in
            let index = lock.withLock { accepted += 1; return accepted }
            onConnection(RemoteTransport(connection: connection, label: "\(label).\(index)"))
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce(continuation)
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready: once.resume(.success(()))
                    case .failed(let error):
                        lock.withLock { failure = "\(error)" }
                        once.resume(.failure(RemoteTransportError.failed(error)))
                    case .waiting(let error):
                        lock.withLock { failure = "\(error)" }
                        once.resume(.failure(RemoteTransportError.waiting(error)))
                    case .cancelled: once.resume(.failure(RemoteTransportError.cancelled))
                    default: break
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    once.resume(.failure(RemoteTransportError.timeout("listener did not become ready")))
                }
            }
        } catch {
            listener.cancel()
            throw error
        }
    }

    func cancel() { listener.cancel() }
}
