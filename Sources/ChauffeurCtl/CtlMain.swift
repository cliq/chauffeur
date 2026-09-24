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
                chauffeurctl event [--session UUID] EVENT [provider-notify-json]
                chauffeurctl inbox-hook --provider claude|codex|opencode [--report-stop] [--report-running]
                chauffeurctl wait-for-work [--timeout MINUTES] [--no-milestones] [--json]

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
                // Provider hook timeouts are a few seconds; never outlast them.
                DispatchQueue.global().asyncAfter(deadline: .now() + hookDeadline) { exit(0) }
                // Without --session the credential names the session, which keeps
                // the command identical across sessions (Codex hook trust hashes it).
                var params: [String: JSONValue] = [:]
                if args.first == "--session" {
                    guard args.count >= 3, let sessionID = UUID(uuidString: args[1]) else { return }
                    params["sessionID"] = .string(sessionID.uuidString); args.removeFirst(2)
                }
                guard let event = args.first, let token = ProcessInfo.processInfo.environment["CHAUFFEUR_SESSION_TOKEN"] else { return }
                params["event"] = .string(event); params["token"] = .string(token)
                let payload = HookPayload.parse(args.count > 1 ? Data(args[1].utf8) : hookInput())
                if let nativeID = payload.conversationID { params["nativeConversationID"] = .string(nativeID) }
                if let hookEvent = payload.hookEvent { params["hookEvent"] = .string(hookEvent) }
                if let source = payload.source { params["source"] = .string(source) }
                _ = try? await RuntimeClient.call(IPCRequest("event", params: .object(params)), socketPath: socket)
                return
            case "inbox-hook":
                await inboxHook(args, socket: socket)
                return
            case "wait-for-work":
                exit(await waitForWork(args, socket: socket))
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
    /// Hook-driven commands exit 0 by this deadline; provider hook timeouts are 5 s.
    private static let hookDeadline: TimeInterval = 3
    /// Prints a metadata-only inbox reminder for a native lifecycle hook. Every
    /// failure prints nothing and exits 0: a hint is best effort, the inbox is durable.
    /// With --report-stop (Claude), a Stop that is allowed to end the turn is also
    /// reported as turn-finished; a Stop this hook blocks is not the end of the turn.
    private static func inboxHook(_ args: [String], socket: String) async {
        DispatchQueue.global().asyncAfter(deadline: .now() + hookDeadline) { exit(0) }
        let payload = HookPayload.parse(hookInput())
        guard let index = args.firstIndex(of: "--provider"), args.indices.contains(index + 1),
              let provider = CLIKind(rawValue: args[index + 1]), provider.isAgent,
              let token = ProcessInfo.processInfo.environment["CHAUFFEUR_SESSION_TOKEN"],
              let event = payload.hookEvent, InboxHintFormatter.hookEvents.contains(event) else { return }
        if provider == .opencode { await openCodeInboxHook(args, payload: payload, event: event, token: token, socket: socket); return }
        var summary: InboxHintSummary?
        // A continuation after a blocked Stop always ends the turn.
        if !(event == "Stop" && payload.stopHookActive) {
            var params: [String: JSONValue] = ["token": .string(token), "provider": .string(provider.rawValue), "event": .string(event)]
            if let nativeID = payload.conversationID { params["nativeConversationID"] = .string(nativeID) }
            if let turnID = payload.turnID { params["turnID"] = .string(turnID) }
            if let toolUseID = payload.toolUseID { params["toolUseID"] = .string(toolUseID) }
            summary = (try? await RuntimeClient.call(IPCRequest("inboxHint", params: .object(params)), socketPath: socket)).flatMap { try? $0.decode(InboxHintSummary.self) }
            if let summary, let output = InboxHintFormatter.output(event: event, summary: summary) { FileHandle.standardOutput.write(output) }
        }
        if event == "Stop", args.contains("--report-stop"), summary?.block != true {
            var params: [String: JSONValue] = ["token": .string(token), "event": .string("turn-finished"), "hookEvent": .string(event)]
            if let nativeID = payload.conversationID { params["nativeConversationID"] = .string(nativeID) }
            if let background = payload.backgroundTasksActive { params["backgroundTasks"] = .number(Double(background)) }
            _ = try? await RuntimeClient.call(IPCRequest("event", params: .object(params)), socketPath: socket)
        }
        // Codex reports status only through notify at the end of a turn; its trusted
        // prompt and tool hooks show that a long turn is still running.
        if event != "Stop", args.contains("--report-running") {
            var params: [String: JSONValue] = ["token": .string(token), "event": .string("running"), "hookEvent": .string(event)]
            if let nativeID = payload.conversationID { params["nativeConversationID"] = .string(nativeID) }
            _ = try? await RuntimeClient.call(IPCRequest("event", params: .object(params)), socketPath: socket)
        }
    }
    /// The OpenCode plugin's hook: always one `{"block","text","waitForWorkers"}` line
    /// once the runtime answers. A continuation Stop (`stop_hook_active`) claims no
    /// mail but still learns whether the coordinator should wait for its workers.
    private static func openCodeInboxHook(_ args: [String], payload: HookPayload, event: String, token: String, socket: String) async {
        var params: [String: JSONValue] = ["token": .string(token), "provider": .string(CLIKind.opencode.rawValue), "event": .string(event)]
        if let nativeID = payload.conversationID { params["nativeConversationID"] = .string(nativeID) }
        if event == "Stop" { params[payload.stopHookActive ? "claim" : "newTurn"] = .bool(!payload.stopHookActive) }
        let summary = (try? await RuntimeClient.call(IPCRequest("inboxHint", params: .object(params)), socketPath: socket)).flatMap { try? $0.decode(InboxHintSummary.self) }
        let output = summary.flatMap { InboxHintFormatter.openCodeOutput(event: event, summary: $0) }
        let block = output.flatMap { try? JSONCoding.decode(JSONValue.self, from: $0) }?["block"].bool == true
        if event == "Stop", args.contains("--report-stop"), !block {
            var stop: [String: JSONValue] = ["token": .string(token), "event": .string("turn-finished"), "hookEvent": .string(event)]
            if let nativeID = payload.conversationID { stop["nativeConversationID"] = .string(nativeID) }
            if output != nil, summary?.waitForWorkers == true { stop["waitingForWorkers"] = .bool(true) }
            _ = try? await RuntimeClient.call(IPCRequest("event", params: .object(stop)), socketPath: socket)
        }
        if let output { FileHandle.standardOutput.write(output + Data("\n".utf8)) }
    }
    /// Run in the background by a coordinator that ended its turn: exits when the
    /// session has a worker result, message, worker state change or progress milestone,
    /// printing what to act on. 0 = work or timeout, 2 = replaced or ended, 1 = error.
    /// With --json (the OpenCode plugin), every outcome is one `{"reason","text"}` line;
    /// failures report `ended`, since the plugin acts only on `work`.
    private static func waitForWork(_ args: [String], socket: String) async -> Int32 {
        let json = args.contains("--json")
        func fail(_ text: String) -> Int32 {
            print(json ? WorkReportFormatter.json(reason: .ended, text: text) : text); return 1
        }
        guard let token = ProcessInfo.processInfo.environment["CHAUFFEUR_SESSION_TOKEN"] else {
            return fail("Chauffeur: wait-for-work must run inside a Chauffeur agent session.")
        }
        var minutes = 240
        if let index = args.firstIndex(of: "--timeout") {
            guard args.indices.contains(index + 1), let value = Int(args[index + 1]), (1...1440).contains(value) else {
                return fail("Chauffeur: --timeout takes 1–1440 minutes.")
            }
            minutes = value
        }
        // The shell that started this wait belongs to the agent. If the agent exits,
        // stop waiting instead of lingering as an orphan.
        let parent = getppid()
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 2, repeating: 2)
        watchdog.setEventHandler { if getppid() != parent { exit(2) } }
        watchdog.resume()
        let params: JSONValue = .object(["token": .string(token), "timeoutSeconds": .number(Double(minutes * 60)),
                                         "milestones": .bool(!args.contains("--no-milestones")), "processID": .number(Double(getpid()))])
        do {
            let result = try await RuntimeClient.call(IPCRequest("waitForWork", params: params), socketPath: socket, responseTimeout: minutes * 60 + 60)
            let report = try result.decode(WorkReport.self)
            print(json ? WorkReportFormatter.json(report) : WorkReportFormatter.text(report))
            return [.replaced, .ended].contains(report.reason) ? 2 : 0
        } catch let error as ChauffeurError where error.code == "socket_failed" || error.code == "connection_closed" || error.code == "service_unavailable" {
            return fail("Chauffeur: cannot reach the Chauffeur service from this shell. A sandbox may block it; wait with chauffeur_inbox instead.")
        } catch {
            return fail("Chauffeur: wait-for-work failed (\((error as? ChauffeurError)?.code ?? "error")). Wait with chauffeur_inbox instead.")
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
