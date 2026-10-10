#if !canImport(Network)
import Foundation
import Glibc
import CChauffeurTLS

// The Linux counterpart of RemoteTransport.swift, with the same API and guarantees over the
// OpenSSL listener in CChauffeurTLS: TLS 1.2 with the RFC 5487 PSK suite.

enum RemoteTLS {
    static let identity = "chauffeur-remote"
}

enum RemoteTransportError: Error, CustomStringConvertible {
    case timeout(String)
    case failed(String)
    case cancelled
    case closed

    var description: String {
        switch self {
        case .timeout(let what): return "timeout: \(what)"
        case .failed(let error): return "connection failed: \(error)"
        case .cancelled: return "connection cancelled"
        case .closed: return "connection closed"
        }
    }
}

/// One thread that runs blocking jobs in submission order. Once stopped it finishes the
/// queued jobs, which fail fast on a closed connection, and exits.
private final class BlockingWorker: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private var stopped = false

    init(name: String) {
        let thread = Thread { [self] in run() }
        thread.name = name
        thread.start()
    }

    func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            condition.lock()
            defer { condition.unlock() }
            guard !stopped else { continuation.resume(throwing: RemoteTransportError.cancelled); return }
            jobs.append { continuation.resume(with: Result { try work() }) }
            condition.signal()
        }
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty && !stopped { condition.wait() }
            guard !jobs.isEmpty else { condition.unlock(); return }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}

/// Async send/receive over one accepted TLS connection. Receives (and the handshake) run on
/// one thread and sends on another, each in call order, so a message is written whole before
/// the next one starts, which is what Network.framework's send queue guarantees on macOS.
/// The threads start with the first call, so connections refused on arrival cost none.
final class RemoteTransport: @unchecked Sendable {
    private let connection: OpaquePointer
    private let label: String
    private let lock = NSLock()
    private var readWorker: BlockingWorker?
    private var writeWorker: BlockingWorker?
    private var started = false
    private var cancelled = false

    init(connection: OpaquePointer, label: String) {
        self.connection = connection
        self.label = label
    }

    // Queued jobs hold the transport, so no thread is inside the connection by now.
    deinit {
        readWorker?.stop()
        writeWorker?.stop()
        ctls_conn_free(connection)
    }

    private var reader: BlockingWorker {
        lock.withLock {
            if let readWorker { return readWorker }
            let worker = BlockingWorker(name: "dev.chauffeur.remote.\(label).read")
            if cancelled { worker.stop() }
            readWorker = worker
            return worker
        }
    }

    private var writer: BlockingWorker {
        lock.withLock {
            if let writeWorker { return writeWorker }
            let worker = BlockingWorker(name: "dev.chauffeur.remote.\(label).write")
            if cancelled { worker.stop() }
            writeWorker = worker
            return worker
        }
    }

    /// Numeric address of the peer, used as the rate-limit key.
    var remoteAddress: String { String(cString: ctls_conn_peer(connection)) }

    /// Runs the server handshake. A wrong pre-shared key fails it.
    func start(timeout: TimeInterval) async throws {
        let first = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard first else { return }
        let milliseconds = Int32(clamping: Int(timeout * 1000))
        do {
            try await reader.perform { [self] in
                var error = [CChar](repeating: 0, count: 256)
                guard ctls_conn_handshake(connection, milliseconds, &error, error.count) == 0 else {
                    let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    throw message.contains("timed out") ? RemoteTransportError.timeout(message) : RemoteTransportError.failed(message)
                }
            }
        } catch {
            cancel()
            throw error
        }
    }

    /// Ends the connection; pending and later sends and receives fail.
    func cancel() {
        let workers = lock.withLock { () -> [BlockingWorker?] in
            cancelled = true
            return [readWorker, writeWorker]
        }
        ctls_conn_close(connection)
        workers.forEach { $0?.stop() }
    }

    func send(_ data: Data) async throws {
        try await writer.perform { [self] in
            let result = data.withUnsafeBytes { bytes in
                ctls_conn_write(connection, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            guard result == 0 else { throw closedError }
        }
    }

    /// The next chunk of bytes, or nil once the peer closed its side.
    func receive(maximumLength: Int) async throws -> Data? {
        try await reader.perform { [self] in
            var buffer = [UInt8](repeating: 0, count: max(1, maximumLength))
            let count = ctls_conn_read(connection, &buffer, buffer.count)
            if count > 0 { return Data(buffer.prefix(count)) }
            if count == 0 { return nil }
            throw closedError
        }
    }

    private var closedError: RemoteTransportError {
        lock.withLock { cancelled } ? .cancelled : .closed
    }
}

/// A TLS listener that reports accepted connections as transports, from its own thread.
final class RemoteListener: @unchecked Sendable {
    private let server: OpaquePointer
    private let label: String
    private let lock = NSLock()
    private var accepted = 0
    private var running = false
    private var failure: String?
    private let onConnection: @Sendable (RemoteTransport) -> Void

    init(psk: Data, port: Int, label: String, onConnection: @escaping @Sendable (RemoteTransport) -> Void) throws {
        var error = [CChar](repeating: 0, count: 256)
        let created = psk.withUnsafeBytes { bytes in
            ctls_server_new(Int32(clamping: port), bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, RemoteTLS.identity, &error, error.count)
        }
        guard let created else {
            throw RemoteTransportError.failed(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        server = created
        self.label = label
        self.onConnection = onConnection
    }

    // The accept thread holds the listener, so this runs only once it has exited.
    deinit { ctls_server_free(server) }

    /// A description of why the listener stopped accepting after it started, if it did.
    var failureDescription: String? { lock.withLock { failure } }

    /// Starts accepting. The socket is already listening, so this can't time out.
    func start(timeout: TimeInterval = 5) async throws {
        let first = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard first else { return }
        let thread = Thread { [self] in
            while let connection = ctls_server_accept(server) {
                let index = lock.withLock { accepted += 1; return accepted }
                onConnection(RemoteTransport(connection: connection, label: "\(label).\(index)"))
            }
            let code = ctls_server_failure(server)
            if code != 0 { lock.withLock { failure = String(cString: strerror(code)) } }
        }
        thread.name = "dev.chauffeur.remote.listener.\(label)"
        thread.start()
    }

    func cancel() { ctls_server_close(server) }
}
#endif
