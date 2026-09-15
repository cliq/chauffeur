import Foundation
import Darwin
import CChauffeur

/// Exactly one reader and serialized writers. shutdown wakes pending reads;
/// descriptor close waits for deinit, preventing descriptor reuse races.
public final class SocketConnection: @unchecked Sendable {
    public let descriptor: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false
    public init(descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
    public convenience init(path: String) throws {
        let descriptor = chauffeur_unix_connect(path)
        guard descriptor >= 0 else { throw ChauffeurError("service_unavailable", "Chauffeur background service is stopped or unavailable. Start or restart it", path: path) }
        self.init(descriptor: descriptor)
    }
    deinit { Darwin.close(descriptor) }
    public func close() {
        stateLock.lock(); defer { stateLock.unlock() }
        if !stopped { stopped = true; shutdown(descriptor, SHUT_RDWR) }
    }
    public func send<T: Encodable>(_ value: T) throws { try sendFrameData(WireProtocol.frame(value)) }
    private func sendFrameData(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw ChauffeurError("connection_closed", "Runtime connection closed") }
                offset += written
            }
        }
    }
    public func receive<T: Decodable>(_ type: T.Type) throws -> T {
        let header = try readExactly(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= WireProtocol.maxFrameBytes else { throw ChauffeurError("invalid_frame", "Invalid IPC frame length") }
        return try JSONCoding.decode(type, from: readExactly(Int(length)))
    }
    public func receiveAsync<T: Decodable & Sendable>(_ type: T.Type) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try self.receive(type)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func sendAsync<T: Encodable & Sendable>(_ value: T) async throws {
        let data = try WireProtocol.frame(value)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try self.sendFrameData(data); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let received = Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw ChauffeurError("connection_closed", "Runtime connection closed") }
                offset += received
            }
        }
        return data
    }
}

public enum RuntimeClient {
    public static func call(_ request: IPCRequest, socketPath: String = Paths.applicationSupport.appendingPathComponent("runtime/runtime.sock").path) async throws -> JSONValue {
        let connection = try SocketConnection(path: socketPath)
        defer { connection.close() }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(connection.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection.descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try await connection.sendAsync(request)
        let response = try await connection.receiveAsync(IPCResponse.self)
        guard response.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "App and background service versions differ. Restart the service") }
        guard response.id == request.id else { throw ChauffeurError("protocol_error", "Runtime response does not match request") }
        if let error = response.error { throw error }
        return response.result ?? .null
    }
}
