import Foundation
import ChauffeurCore

/// Kimi persists MCP registrations in its shared home. Without a Chauffeur
/// launch this is a valid empty server; during a launch it forwards to that
/// runtime's authenticated HTTP endpoint. No session data lives in the plugin.
enum KimiMCP {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let token = environment["CHAUFFEUR_KIMI_TOKEN"] ?? ""
        let endpoint = environment["CHAUFFEUR_KIMI_ENDPOINT"].flatMap(URL.init(string:))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 360
        configuration.timeoutIntervalForResource = 360
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let output = Output()
        await withDiscardingTaskGroup { requests in
            while let line = readLine() {
                guard line.utf8.count <= 1024 * 1024,
                      let body = try? JSONCoding.decode(JSONValue.self, from: Data(line.utf8)),
                      case .object(let fields) = body, let id = fields["id"] else { continue }
                requests.addTask {
                    let reply = await response(body: body, id: id, line: line, token: token, endpoint: endpoint, session: session)
                    await output.write(reply)
                }
            }
        }
    }

    private static func response(body: JSONValue, id: JSONValue, line: String, token: String, endpoint: URL?, session: URLSession) async -> JSONValue {
        let reply: JSONValue
        if token.isEmpty {
            let result: JSONValue
            switch body["method"].string {
            case "initialize":
                result = .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object(["tools": .object([:])]),
                                  "serverInfo": .object(["name": .string("chauffeur"), "version": .string("1.0.0")])])
            case "tools/list": result = .object(["tools": .array([])])
            case "ping": result = .object([:])
            default:
                return error(id: id, message: "Chauffeur tools are available in Chauffeur sessions")
            }
            reply = .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        } else if let endpoint, endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.path == "/mcp" {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.httpBody = Data(line.utf8)
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1024 * 1024 else {
                    throw ChauffeurError("kimi_mcp", "Chauffeur MCP request failed")
                }
                reply = try JSONCoding.decode(JSONValue.self, from: data)
            } catch { reply = self.error(id: id, message: "Chauffeur MCP request failed") }
        } else { reply = error(id: id, message: "Chauffeur MCP endpoint is unavailable") }
        return reply
    }

    private static func error(id: JSONValue, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32603), "message": .string(message)])])
    }
    /// Requests can finish out of order; each JSON-RPC line stays intact.
    private actor Output {
        func write(_ value: JSONValue) {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(value) { FileHandle.standardOutput.write(data + Data([10])) }
        }
    }
}
