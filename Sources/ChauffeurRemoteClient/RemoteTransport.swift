import Foundation
import Network
import Security
import ChauffeurRemoteProtocol

public enum RemoteTransportEvent: Sendable {
    case ready
    case bytes(Data)
    case failed(RemoteClientError)
    case closed
}

/// A byte pipe to the Mac runtime. `events` has exactly ONE consumer (the `RemoteConnection`
/// read loop). `send` completes once the bytes were handed to the network so callers get
/// natural backpressure. After `.failed` or `.closed` the stream finishes.
public protocol RemoteTransport: AnyObject, Sendable {
    var events: AsyncStream<RemoteTransportEvent> { get }
    func start()
    func send(_ data: Data) async throws
    func cancel()
}

public struct RemoteEndpoint: Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

// MARK: - Network.framework

/// TLS-PSK transport over Network.framework, identical on iOS and macOS. Mirrors the working
/// configuration from `Prototypes/psk-transport-spike`: TLS pinned to 1.2 with
/// `TLS_PSK_WITH_AES_128_GCM_SHA256`, PSK identity `chauffeur-remote`, TCP no-delay.
///
/// The event stream is unbounded: the client must never drop bytes from the host (the host
/// bounds its output per attachment and ends the attachment with `slowConsumer` instead).
public final class NetworkTransport: RemoteTransport, @unchecked Sendable {
    public static let pskIdentity = "chauffeur-remote"
    public static let connectTimeout: TimeInterval = 10
    public static let maxReceiveBytes = 64 * 1024

    public let events: AsyncStream<RemoteTransportEvent>

    private let continuation: AsyncStream<RemoteTransportEvent>.Continuation
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var isReady = false
    private var isFinished = false

    public init(
        endpoint: RemoteEndpoint,
        presharedKey: Data,
        queue: DispatchQueue = DispatchQueue(label: "chauffeur.remote.transport")
    ) {
        (events, continuation) = AsyncStream.makeStream(of: RemoteTransportEvent.self, bufferingPolicy: .unbounded)
        self.queue = queue
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: max(0, endpoint.port))) ?? .any
        connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: Self.makeParameters(presharedKey: presharedKey)
        )
    }

    /// The exact `NWParameters` the spike validated against the macOS listener and the iOS simulator.
    public static func makeParameters(presharedKey: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        let pskDispatchData = presharedKey.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityDispatchData = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, pskDispatchData as __DispatchData, identityDispatchData as __DispatchData)

        // tls_ciphersuite_t has no PSK cases; build it from the legacy SecureTransport constant (0x00A8).
        // Imported C enums accept any raw value, so the force-unwrap never fires.
        let pskSuite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        sec_protocol_options_append_tls_ciphersuite(sec, pskSuite)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            guard let self else { return }
            let stillConnecting = self.lock.withLock { !self.isReady && !self.isFinished }
            guard stillConnecting else { return }
            self.finish(with: .failed(.timeout))
            self.connection.cancel()
        }
    }

    public func send(_ data: Data) async throws {
        let canSend = lock.withLock { isReady && !isFinished }
        guard canSend else { throw RemoteClientError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: RemoteClientError.network(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func cancel() {
        finish(with: .closed)
        connection.cancel()
    }

    // MARK: State

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            lock.withLock { isReady = true }
            continuation.yield(.ready)
            receiveNext()
        case .waiting(let error):
            // A wrong PSK surfaces as `.waiting` with a TLS error, not `.failed`; Network.framework
            // would retry forever, so it is terminal here. A refused port is reported right away too
            // instead of waiting out the connect deadline.
            switch error {
            case .tls:
                finish(with: .failed(.authenticationFailed))
                connection.cancel()
            case .posix(let code) where code == .ECONNREFUSED:
                finish(with: .failed(.network(String(describing: error))))
                connection.cancel()
            default:
                break
            }
        case .failed(let error):
            finish(with: .failed(.network(String(describing: error))))
        case .cancelled:
            finish(with: .closed)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxReceiveBytes) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                let open = self.lock.withLock { !self.isFinished }
                if open {
                    self.continuation.yield(.bytes(content))
                }
            }
            if let error {
                self.finish(with: .failed(.network(String(describing: error))))
                return
            }
            if isComplete {
                self.finish(with: .closed)
                self.connection.cancel()
                return
            }
            self.receiveNext()
        }
    }

    /// Emits the terminal event once and finishes the stream.
    private func finish(with event: RemoteTransportEvent) {
        let shouldEmit: Bool = lock.withLock {
            if isFinished { return false }
            isFinished = true
            return true
        }
        guard shouldEmit else { return }
        continuation.yield(event)
        continuation.finish()
    }
}

// MARK: - In-memory pair

/// One end of an `InMemoryTransportPair`. `send` delivers to the peer's event stream in call
/// order. Tests can inject a failure or close either end.
public final class InMemoryTransport: RemoteTransport, @unchecked Sendable {
    public let events: AsyncStream<RemoteTransportEvent>

    private let continuation: AsyncStream<RemoteTransportEvent>.Continuation
    private let lock = NSLock()
    private var isOpen = true
    private var isStarted = false
    private weak var peer: InMemoryTransport?

    fileprivate init() {
        (events, continuation) = AsyncStream.makeStream(of: RemoteTransportEvent.self, bufferingPolicy: .unbounded)
    }

    fileprivate func connect(to peer: InMemoryTransport) {
        self.peer = peer
    }

    public func start() {
        let shouldSignal: Bool = lock.withLock {
            guard isOpen, !isStarted else { return false }
            isStarted = true
            return true
        }
        if shouldSignal {
            continuation.yield(.ready)
        }
    }

    public func send(_ data: Data) async throws {
        let open = lock.withLock { isOpen }
        guard open, let peer else { throw RemoteClientError.disconnected }
        peer.receive(data)
    }

    /// Closes this end; the peer observes the close too, like a real socket.
    public func cancel() {
        guard terminate(with: .closed) else { return }
        peer?.terminate(with: .closed)
    }

    /// Delivers `.failed(error)` to this end only and finishes its stream.
    public func fail(_ error: RemoteClientError) {
        terminate(with: .failed(error))
    }

    /// Delivers `.closed` to this end only (the peer keeps running).
    public func close() {
        terminate(with: .closed)
    }

    private func receive(_ data: Data) {
        let open = lock.withLock { isOpen }
        guard open else { return }
        continuation.yield(.bytes(data))
    }

    @discardableResult
    private func terminate(with event: RemoteTransportEvent) -> Bool {
        let shouldEmit: Bool = lock.withLock {
            guard isOpen else { return false }
            isOpen = false
            return true
        }
        guard shouldEmit else { return false }
        continuation.yield(event)
        continuation.finish()
        return true
    }
}

/// Two transports connected in memory; whatever one end sends appears on the other's stream.
public final class InMemoryTransportPair: Sendable {
    public let client: InMemoryTransport
    public let server: InMemoryTransport

    public init() {
        client = InMemoryTransport()
        server = InMemoryTransport()
        client.connect(to: server)
        server.connect(to: client)
    }

    public func closeBoth() {
        client.close()
        server.close()
    }

    public func failClient(_ error: RemoteClientError) {
        client.fail(error)
    }
}
