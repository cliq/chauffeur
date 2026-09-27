import Foundation
import Testing
import ChauffeurCore

struct KimiMCPBridgeTests {
    private final class Marker {}
    @Test func ordinaryKimiLaunchGetsAnEmptyMCPServerWithoutCredentials() throws {
        let ctl = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("chauffeurctl")
        let process = Process(); process.executableURL = ctl; process.arguments = ["kimi-mcp"]
        process.environment = [:]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n".utf8))
        try input.fileHandleForWriting.close()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(lines.count == 2)
        if lines.count == 2 {
            let replies = try lines.map { try JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
            let initialized = try #require(replies.first { $0["id"].int == 1 })
            let tools = try #require(replies.first { $0["id"].int == 2 })
            #expect(initialized["result"]["serverInfo"]["name"].string == "chauffeur")
            #expect(tools["result"]["tools"] == .array([]))
        }
    }
    @Test func aLongRequestDoesNotBlockOtherMCPCalls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("server.py"), portFile = root.appendingPathComponent("port")
        try #"""
        import json, pathlib, sys, threading, time
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        released = threading.Event()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                if request['method'] == 'slow':
                    released.wait(1)
                    time.sleep(0.1)
                else: released.set()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':{}}).encode())
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
        server.serve_forever()
        """#.write(to: script, atomically: true, encoding: .utf8)
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, portFile.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: portFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        let port = try String(contentsOf: portFile, encoding: .utf8)
        let ctl = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("chauffeurctl")
        let process = Process(); process.executableURL = ctl; process.arguments = ["kimi-mcp"]
        process.environment = ["CHAUFFEUR_KIMI_TOKEN": "fixture", "CHAUFFEUR_KIMI_ENDPOINT": "http://127.0.0.1:\(port)/mcp"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":1,"method":"slow"}"#.utf8) + Data([10]))
        // Ensure the wait has begun before sending a request that can release it.
        try await Task.sleep(for: .milliseconds(100))
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8) + Data([10]))
        try input.fileHandleForWriting.close()
        let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
        process.waitUntilExit()
        let ids = try lines.map { try JSONCoding.decode(JSONValue.self, from: Data($0.utf8))["id"].int }
        #expect(ids == [2, 1])
    }

}
