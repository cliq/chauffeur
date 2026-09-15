import Foundation
import Darwin
import ChauffeurCore

@main struct ChauffeurCtlMain {
    static func main() async {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            let command = args.isEmpty ? "help" : args.removeFirst()
            if command == "internal-exec" { try execPayload(args); return }
            var socket = ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] ?? Paths.applicationSupport.appendingPathComponent("runtime/runtime.sock").path
            if let index = args.firstIndex(of: "--socket"), args.indices.contains(index + 1) { socket = args[index + 1]; args.removeSubrange(index...index+1) }
            let request: IPCRequest
            switch command {
            case "help", "--help", "-h":
                print("""
                chauffeurctl status [--socket PATH]
                chauffeurctl snapshot [--socket PATH]
                chauffeurctl request METHOD [JSON | --file PATH] [--socket PATH]
                chauffeurctl event --session UUID EVENT [provider-notify-json]

                request sends structured commands to the per-user service. Native
                hook payloads are reduced to event and conversation IDs; never logged.
                """)
                return
            case "status", "snapshot": request = IPCRequest(command)
            case "request":
                guard !args.isEmpty else { throw ChauffeurError("usage", "request requires a method") }
                let method = args.removeFirst()
                let data: Data
                if args.first == "--file", args.count == 2 { data = try Data(contentsOf: URL(fileURLWithPath: args[1])) }
                else { data = Data((args.first ?? "{}").utf8) }
                request = IPCRequest(method, params: try JSONCoding.decode(JSONValue.self, from: data))
            case "event":
                guard args.count >= 3, args[0] == "--session", let sessionID = UUID(uuidString: args[1]), let token = ProcessInfo.processInfo.environment["CHAUFFEUR_SESSION_TOKEN"] else { throw ChauffeurError("usage", "event requires a session ID, event, and session credential environment") }
                var params: [String: JSONValue] = ["sessionID": .string(sessionID.uuidString), "event": .string(args[2]), "token": .string(token)]
                var payload: JSONValue = .null
                if args.count > 3 { payload = (try? JSONCoding.decode(JSONValue.self, from: Data(args[3].utf8))) ?? .null }
                else if isatty(STDIN_FILENO) == 0, let data = try FileHandle.standardInput.read(upToCount: 65_536) { payload = (try? JSONCoding.decode(JSONValue.self, from: data)) ?? .null }
                if let nativeID = payload["thread-id"].string ?? payload["session_id"].string, UUID(uuidString: nativeID) != nil { params["nativeConversationID"] = .string(nativeID) }
                request = IPCRequest("event", params: .object(params))
            default: throw ChauffeurError("usage", "Unknown command. Run chauffeurctl help")
            }
            let result = try await RuntimeClient.call(request, socketPath: socket)
            if command != "event" { print(String(decoding: try JSONCoding.encode(result), as: UTF8.self)) }
        } catch {
            FileHandle.standardError.write(Data(((error as? ChauffeurError)?.errorDescription ?? "chauffeurctl operation failed").utf8) + Data("\n".utf8))
            exit(1)
        }
    }
    private static func execPayload(_ args: [String]) throws {
        guard args.count == 1 else { throw ChauffeurError("usage", "Invalid launch handoff") }
        let path = args[0]
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_size <= 1024 * 1024 else {
            throw ChauffeurError("invalid_handoff", "Launch handoff must be a private, owned regular file")
        }
        let payload = try JSONCoding.decode(ExecPayload.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard unlink(path) == 0 else { throw ChauffeurError("handoff_cleanup", "Cannot consume launch handoff") }
        _ = try Paths.directory(payload.directory)
        guard chdir(payload.directory) == 0 else { throw ChauffeurError("working_directory", "Cannot enter selected directory") }
        var argv = ([payload.executable] + payload.arguments).map { strdup($0) } + [nil]
        var envp = payload.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        execve(payload.executable, &argv, &envp)
        throw ChauffeurError("exec_failed", "Selected executable could not start", path: payload.executable)
    }
}
