import Foundation
import Darwin
import CChauffeur
import ChauffeurCore

public final class IPCServer: @unchecked Sendable {
    private let descriptor: Int32
    private let lockDescriptor: Int32
    private let path: String
    private let runtime: RuntimeCoordinator
    public init(root: URL, runtime: RuntimeCoordinator) throws {
        let directory = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lockDescriptor = chauffeur_lock(directory.appendingPathComponent("runtime.lock").path)
        guard lockDescriptor >= 0 else { throw ChauffeurError("runtime_already_running", "Another Chauffeur runtime owns this data directory") }
        path = directory.appendingPathComponent("runtime.sock").path
        unlink(path)
        descriptor = chauffeur_unix_listen(path)
        guard descriptor >= 0 else { Darwin.close(lockDescriptor); throw ChauffeurError("socket_failed", "Cannot open runtime socket; check path length and permissions", path: path) }
        self.runtime = runtime
    }
    deinit { Darwin.close(descriptor); unlink(path); Darwin.close(lockDescriptor) }
    public func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while true {
                let accepted = Darwin.accept(descriptor, nil, nil)
                if accepted < 0 && errno == EINTR { continue }
                guard accepted >= 0 else { return }
                guard chauffeur_peer_is_current_user(accepted) != 0 else { Darwin.close(accepted); continue }
                let connection = SocketConnection(descriptor: accepted)
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(accepted, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                Task { await serve(connection) }
            }
        }
    }
    private func serve(_ connection: SocketConnection) async {
        defer { connection.close() }
        do {
            while true {
                let request = try await connection.receiveAsync(IPCRequest.self)
                if request.method == "attach" {
                    try await serveTerminal(connection, request: request); return
                }
                if request.method == "subscribe" {
                    guard request.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "Restart app and runtime to use matching versions") }
                    var last: String?
                    var heartbeat = ContinuousClock.now
                    while !Task.isCancelled {
                        let snapshot = try await runtime.snapshot()
                        let hash = JSONCoding.digest(try JSONCoding.encode(snapshot))
                        if hash != last || ContinuousClock.now - heartbeat >= .seconds(5) {
                            try await connection.sendAsync(IPCResponse(id: request.id, result: snapshot)); last = hash; heartbeat = .now
                        }
                        try await Task.sleep(for: .seconds(1))
                    }
                    return
                }
                let response: IPCResponse
                do { response = IPCResponse(id: request.id, result: try await runtime.handle(request)) }
                catch {
                    let failure = error as? ChauffeurError ?? ChauffeurError("operation_failed", "Runtime operation failed")
                    await runtime.record(failure)
                    response = IPCResponse(id: request.id, error: failure)
                }
                try await connection.sendAsync(response)
            }
        } catch { /* EOF or detached UI: agent ownership is unchanged. */ }
    }
    private func serveTerminal(_ connection: SocketConnection, request: IPCRequest) async throws {
        let sessionID = try request.params.uuid("sessionID"), owner = try request.params.uuid("owner")
        guard request.version == WireProtocol.major else { try await connection.sendAsync(IPCResponse(id: request.id, error: ChauffeurError("protocol_mismatch", "App and service versions differ"))); return }
        try await connection.sendAsync(IPCResponse(id: request.id, result: .object(["stream": .bool(true)])))
        do {
            try await runtime.attach(sessionID: sessionID, owner: owner, connection: connection, cols: request.params["cols"].int ?? 100, rows: request.params["rows"].int ?? 30)
            while true {
                let packet = try await connection.receiveAsync(IPCRequest.self)
                guard packet.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "Terminal protocol changed") }
                switch packet.method {
                case "input":
                    guard let encoded = packet.params["bytes"].string, let bytes = Data(base64Encoded: encoded) else { throw ChauffeurError("invalid_input", "Invalid terminal input") }
                    try await runtime.terminals.input(sessionID: sessionID, owner: owner, bytes: bytes)
                case "resize": try await runtime.terminals.resize(sessionID: sessionID, owner: owner, cols: packet.params["cols"].int ?? 100, rows: packet.params["rows"].int ?? 30)
                case "detach": await runtime.terminals.detach(sessionID: sessionID, owner: owner); return
                default: throw ChauffeurError("unknown_terminal_command", "Invalid terminal command")
                }
            }
        } catch {
            try? await connection.sendAsync(TerminalPacket(kind: "error", message: (error as? ChauffeurError)?.message ?? "Terminal detached"))
            await runtime.terminals.detach(sessionID: sessionID, owner: owner)
        }
    }
}
