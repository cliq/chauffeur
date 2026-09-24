import Foundation
import Hummingbird
import HTTPTypes
import ChauffeurCore

public enum MCPServer {
    public static func run(runtime: RuntimeCoordinator, port: Int) async throws {
        let router = Router()
        router.post("/mcp") { request, _ -> Response in
            guard validOrigin(request) else { return Response(status: .forbidden) }
            guard let authority = request.head.authority, let host = authority.split(separator: ":").first, ["127.0.0.1", "localhost"].contains(String(host)) else { return Response(status: .forbidden) }
            guard let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer ") else { return Response(status: .unauthorized) }
            let token = String(authorization.dropFirst(7))
            do { _ = try await runtime.ledger.authenticate(token) } catch { return Response(status: .unauthorized) }
            guard request.headers[.contentType]?.hasPrefix("application/json") == true else { return Response(status: .unsupportedMediaType) }
            if let version = request.headers[HTTPField.Name("MCP-Protocol-Version")!], !["2025-11-25", "2025-06-18", "2025-03-26"].contains(version) { return Response(status: .badRequest) }
            let data: Data
            do { data = Data(try await request.body.collect(upTo: 1024 * 1024).readableBytesView) }
            catch { return Response(status: .contentTooLarge) }
            let body: JSONValue
            do { body = try JSONCoding.decode(JSONValue.self, from: data) }
            catch { return try json(rpcError(id: .null, code: -32700, message: "Parse error")) }
            guard case .object(let fields) = body, body["jsonrpc"].string == "2.0", let method = body["method"].string else { return try json(rpcError(id: .null, code: -32600, message: "Invalid request")) }
            guard let requestID = fields["id"] else { return Response(status: .accepted) }
            switch requestID {
            case .string, .number: break
            default: return try json(rpcError(id: .null, code: -32600, message: "Invalid request ID"))
            }
            let result: JSONValue
            switch method {
            case "initialize": result = .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object(["tools": .object([:])]), "serverInfo": .object(["name": .string("chauffeur"), "version": .string(RuntimeVersion.current)]), "instructions": .string("Use chauffeur_discover for your authenticated group. Messages are durable inbox entries; they do not automatically wake a CLI. Use bounded inbox waits when awaiting delegated work.")])
            case "ping": result = .object([:])
            case "tools/list":
                let short = await runtime.exposesShortToolNames(token: token)
                result = .object(["tools": .array(short ? MCPTools.definitions.map(MCPTools.withoutPrefix) : MCPTools.definitions)])
            case "tools/call":
                do {
                    let value = try await runtime.callTool(token: token, name: MCPTools.prefixed(body["params"].requiredString("name")), arguments: body["params"]["arguments"] == .null ? .object([:]) : body["params"]["arguments"])
                    result = .object(["content": .array([.object(["type": .string("text"), "text": .string(String(decoding: try JSONCoding.encode(value), as: UTF8.self))])]), "isError": .bool(false)])
                } catch {
                    await runtime.record(error as? ChauffeurError ?? ChauffeurError("operation_failed", "Tool operation failed"))
                    let safe = (error as? ChauffeurError)?.message ?? "Tool operation failed"
                    result = .object(["content": .array([.object(["type": .string("text"), "text": .string(safe)])]), "isError": .bool(true)])
                }
            default: return try json(rpcError(id: requestID, code: -32601, message: "Method not found"))
            }
            return try json(.object(["jsonrpc": .string("2.0"), "id": requestID, "result": result]))
        }
        // Stateless JSON transport. No resources/subscriptions are advertised.
        router.get("/mcp") { request, _ -> Response in
            guard validOrigin(request) else { return Response(status: .forbidden) }
            guard let authorization = request.headers[.authorization], authorization.hasPrefix("Bearer ") else { return Response(status: .unauthorized) }
            do { _ = try await runtime.ledger.authenticate(String(authorization.dropFirst(7))) } catch { return Response(status: .unauthorized) }
            return Response(status: .methodNotAllowed, headers: [.allow: "POST"])
        }
        let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: port)), onServerRunning: { channel in
            if let port = channel.localAddress?.port {
                await runtime.setEndpoint(port: port)
                do { try JSONCoding.encode(port).write(to: runtime.root.appendingPathComponent("runtime/mcp-port.json"), options: .atomic) }
                catch { await runtime.record(ChauffeurError("port_persistence", "Cannot persist MCP port for service restart")) }
            }
        })
        try await app.runService()
    }
    private static func rpcError(id: JSONValue, code: Int, message: String) -> JSONValue { .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])]) }
    private static func validOrigin(_ request: Request) -> Bool {
        guard let authority = request.head.authority, let host = authority.split(separator: ":").first, ["127.0.0.1", "localhost"].contains(String(host)) else { return false }
        guard let origin = request.headers[.origin] else { return true }
        guard let url = URL(string: origin), url.scheme == "http", ["127.0.0.1", "localhost"].contains(url.host ?? ""), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return false }
        let port = authority.split(separator: ":").count == 2 ? Int(authority.split(separator: ":")[1]) : 80
        return (url.port ?? 80) == port
    }
    private static func json(_ value: JSONValue) throws -> Response {
        Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: .init(bytes: try JSONCoding.encode(value))))
    }
}
