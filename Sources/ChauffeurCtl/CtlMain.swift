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
                chauffeurctl diagnostics [--socket PATH]
                chauffeurctl request METHOD [JSON | --file PATH] [--socket PATH]
                chauffeurctl event --session UUID EVENT [provider-notify-json]
                chauffeurctl inbox-hook --provider claude|codex

                request sends structured commands to the per-user service. Native
                hook payloads are reduced to event and conversation IDs; never logged.
                """)
                return
            case "status", "snapshot", "diagnostics": request = IPCRequest(command)
            case "request":
                guard !args.isEmpty else { throw ChauffeurError("usage", "request requires a method") }
                let method = args.removeFirst()
                let data: Data
                if args.first == "--file", args.count == 2 { data = try Data(contentsOf: URL(fileURLWithPath: args[1])) }
                else { data = Data((args.first ?? "{}").utf8) }
                request = IPCRequest(method, params: try JSONCoding.decode(JSONValue.self, from: data))
            case "event":
                // Native hooks call this. A rejected event must not surface as a
                // provider hook error; the runtime records its own diagnostics.
                guard args.count >= 3, args[0] == "--session", let sessionID = UUID(uuidString: args[1]), let token = ProcessInfo.processInfo.environment["CHAUFFEUR_SESSION_TOKEN"] else { return }
                var params: [String: JSONValue] = ["sessionID": .string(sessionID.uuidString), "event": .string(args[2]), "token": .string(token)]
                let payload = HookPayload.parse(args.count > 3 ? Data(args[3].utf8) : hookInput())
                if let nativeID = payload.conversationID { params["nativeConversationID"] = .string(nativeID) }
                if let hookEvent = payload.hookEvent { params["hookEvent"] = .string(hookEvent) }
                if let source = payload.source { params["source"] = .string(source) }
                _ = try? await RuntimeClient.call(IPCRequest("event", params: .object(params)), socketPath: socket)
                return
            case "inbox-hook":
                await inboxHook(args, socket: socket)
                return
            default: throw ChauffeurError("usage", "Unknown command. Run chauffeurctl help")
            }
            let result = try await RuntimeClient.call(request, socketPath: socket)
            print(String(decoding: try JSONCoding.encode(result), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data(((error as? ChauffeurError)?.errorDescription ?? "chauffeurctl operation failed").utf8) + Data("\n".utf8))
            exit(1)
        }
    }
    /// Reads a bounded hook payload and drains the rest so the provider never
    /// blocks writing a large tool response into a closed pipe.
    private static func hookInput() -> Data {
        guard isatty(STDIN_FILENO) == 0 else { return Data() }
        let input = FileHandle.standardInput
        let data = (try? input.read(upToCount: HookPayload.readLimit)) ?? nil
        while let more = try? input.read(upToCount: HookPayload.readLimit), !more.isEmpty {}
        return data ?? Data()
    }
    /// Prints a metadata-only inbox reminder for a native lifecycle hook. Every
    /// failure prints nothing and exits 0: a hint is best effort, the inbox is durable.
    private static func inboxHook(_ args: [String], socket: String) async {
        // Hook timeouts are a few seconds; give up well before the provider does.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { exit(0) }
        let payload = HookPayload.parse(hookInput())
        guard let index = args.firstIndex(of: "--provider"), args.indices.contains(index + 1),
              let provider = CLIKind(rawValue: args[index + 1]), provider.isAgent,
              let token = ProcessInfo.processInfo.environment["CHAUFFEUR_SESSION_TOKEN"],
              let event = payload.hookEvent, InboxHintFormatter.hookEvents.contains(event),
              // A continuation after a blocked Stop always ends the turn.
              !(event == "Stop" && payload.stopHookActive) else { return }
        var params: [String: JSONValue] = ["token": .string(token), "provider": .string(provider.rawValue), "event": .string(event)]
        if let nativeID = payload.conversationID { params["nativeConversationID"] = .string(nativeID) }
        if let turnID = payload.turnID { params["turnID"] = .string(turnID) }
        if let toolUseID = payload.toolUseID { params["toolUseID"] = .string(toolUseID) }
        guard let result = try? await RuntimeClient.call(IPCRequest("inboxHint", params: .object(params)), socketPath: socket),
              let summary = try? result.decode(InboxHintSummary.self),
              let output = InboxHintFormatter.output(event: event, summary: summary) else { return }
        FileHandle.standardOutput.write(output)
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
        if let preamble = payload.preamble, !preamble.isEmpty {
            // Shown dimmed at the top of the terminal so the user sees what this session applied.
            let lines = preamble.split(separator: "\n", omittingEmptySubsequences: false).map { "\u{1b}[2m\($0)\u{1b}[0m\r\n" }
            FileHandle.standardOutput.write(Data(lines.joined().utf8))
        }
        var argv = ([payload.executable] + payload.arguments).map { strdup($0) } + [nil]
        var envp = payload.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        execve(payload.executable, &argv, &envp)
        throw ChauffeurError("exec_failed", "Selected executable could not start", path: payload.executable)
    }
}
