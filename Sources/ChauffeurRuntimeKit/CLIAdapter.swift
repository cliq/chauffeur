import Foundation
import ChauffeurCore

public struct CLICapabilities: Codable, Sendable {
    public var version: String
    public var coordination: Bool
    public var statusSignals: Bool
    public var additionalDirectories: Bool
    public var resume: Bool
    public var delegatedYOLO: Bool
    public var limitation: String?
}

public enum CLIAdapter {
    public static func capabilities(executable: String, kind: CLIKind, environment: [String: String]) async throws -> CLICapabilities {
        let version = try await ProcessRunner.run(executable, ["--version"], environment: environment)
        guard version.status == 0 else { throw ChauffeurError("version_failed", "Executable does not report its version", path: executable) }
        let help = try await ProcessRunner.run(executable, ["--help"], environment: environment)
        guard help.status == 0 else { throw ChauffeurError("help_failed", "Executable does not report its supported options", path: executable) }
        let text = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Native CLIs update frequently. Identify the provider without pinning a
        // release number; feature flags below are discovered from native help.
        let baseline = identifiesProvider(kind: kind, version: text)
        let delegatedYOLO = switch kind {
        case .codex: help.output.contains("--dangerously-bypass-approvals-and-sandbox")
        case .claude: help.output.contains("--dangerously-skip-permissions")
        case .shell: false
        }
        return CLICapabilities(version: String(text.prefix(200)), coordination: baseline, statusSignals: baseline, additionalDirectories: help.output.contains("--add-dir"), resume: help.output.contains("resume"), delegatedYOLO: delegatedYOLO, limitation: baseline ? (kind == .codex ? "Turn completion via notify; approval/input detection is unavailable" : nil) : "The executable does not identify itself as the selected agent. Check the preset executable, or use basic terminal mode")
    }
    public static func identifiesProvider(kind: CLIKind, version: String) -> Bool {
        switch kind {
        case .codex: version.hasPrefix("codex-cli ")
        case .claude: version.hasSuffix("(Claude Code)")
        case .shell: false
        }
    }

    /// Codex hooks Chauffeur adds for a coordinated session. The commands carry no
    /// session ID (the session comes from `CHAUFFEUR_SESSION_TOKEN`), so their
    /// trust hashes stay the same across sessions.
    public static func codexHookDefinitions(ctlPath: String) -> [CodexHookTrust.Definition] {
        let inbox = [ctlPath, "inbox-hook", "--provider", "codex"].map(shellQuote).joined(separator: " ")
        return [CodexHookTrust.Definition(event: "SessionStart", command: [ctlPath, "event", "session-start"].map(shellQuote).joined(separator: " "))]
            + ["UserPromptSubmit", "PostToolUse", "Stop"].map { CodexHookTrust.Definition(event: $0, command: inbox) }
    }
    public static func codexHookArguments(_ definitions: [CodexHookTrust.Definition]) throws -> [String] {
        try definitions.flatMap { ["-c", "hooks.\($0.event)=[{hooks=[{type=\"command\",command=\(try tomlLiteral($0.command)),timeout=5}]}]"] }
    }

    /// `codexHookTrust` holds the `hooks/list` hashes for Chauffeur's Codex hooks.
    /// Without it, Codex launches with MCP and `notify` only.
    public static func arguments(session: Session, endpoint: String, ctlPath: String, integrationDirectory: URL, coordination: Bool, resume: Bool, codexHookTrust: [String: String]? = nil) throws -> [String] {
        let preset = session.launch.preset
        let resolved: [String]
        if let snapshotArguments = session.launch.resolvedArguments { resolved = snapshotArguments }
        else { resolved = try LaunchOptions.resolve(preset: preset).arguments }
        try LaunchPolicy.validateArguments(resolved, kind: preset.kind)
        var arguments = resolved
        switch preset.kind {
        case .shell:
            guard !resume else { throw ChauffeurError("resume_unavailable", "Shell sessions cannot be resumed. Open a new shell") }
        case .codex:
            arguments += ["-C", session.launch.workingDirectory]
            for path in session.launch.additionalPaths { arguments += ["--add-dir", path] }
            if coordination {
                arguments += ["-c", "mcp_servers.chauffeur.url=\(try tomlLiteral(endpoint))", "-c", "mcp_servers.chauffeur.bearer_token_env_var=\(try tomlLiteral("CHAUFFEUR_SESSION_TOKEN"))"]
                arguments += ["-c", "mcp_servers.chauffeur.tool_timeout_sec=360"]
                let notify = [ctlPath, "event", "--session", session.id.uuidString, "turn-finished"]
                arguments += ["-c", "notify=\(try tomlLiteral(notify))"]
                // A blocking Stop is not the end of a turn, so status still comes from notify.
                if let codexHookTrust {
                    arguments += try codexHookArguments(codexHookDefinitions(ctlPath: ctlPath))
                    arguments += ["-c", try CodexHookTrust.stateArgument(codexHookTrust)]
                }
            }
            if resume {
                guard let id = session.nativeConversationID, UUID(uuidString: id) != nil else { throw ChauffeurError("resume_unavailable", "No native conversation ID was recorded") }
                arguments += ["resume", id]
            } else if let task = session.initialTask, !task.isEmpty { arguments += ["--", task] }
        case .claude:
            if resume {
                guard let id = session.nativeConversationID, UUID(uuidString: id) != nil else { throw ChauffeurError("resume_unavailable", "No native conversation ID was recorded") }
                arguments += ["--resume", id]
            } else { arguments += ["--session-id", session.nativeConversationID ?? session.id.uuidString] }
            for path in session.launch.additionalPaths { arguments += ["--add-dir", path] }
            if coordination {
                let config: JSONValue = .object(["mcpServers": .object(["chauffeur": .object([
                    "type": .string("http"), "url": .string(endpoint), "timeout": .number(360_000),
                    "headers": .object(["Authorization": .string("Bearer ${CHAUFFEUR_SESSION_TOKEN}")])
                ])])])
                let configPath = integrationDirectory.appendingPathComponent("mcp.json")
                try JSONCoding.encode(config).write(to: configPath, options: .atomic)
                var hooks: [String: JSONValue] = [:]
                for (hook, event) in [("SessionStart", "running"), ("UserPromptSubmit", "running"),
                                      ("PostToolUse", "running"), ("PostToolUseFailure", "running"),
                                      ("StopFailure", "needs-attention"),
                                      ("Notification", "needs-attention"), ("PermissionRequest", "needs-attention")] {
                    let command = [ctlPath, "event", "--session", session.id.uuidString, event].map(shellQuote).joined(separator: " ")
                    var group: [String: JSONValue] = ["hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .number(5)])])]
                    if hook == "Notification" {
                        // Idle reminders and successful authentication are not
                        // blocked input. Keep completion until a real signal.
                        group["matcher"] = .string("^(permission_prompt|elicitation_dialog|elicitation_url_dialog)$")
                    }
                    hooks[hook] = .array([.object(group)])
                }
                // Metadata-only mail reminders run beside the status hooks. No
                // matcher on PostToolUse, so Chauffeur's own MCP tools count too.
                // Stop has a single hook: it reports turn-finished only when it does
                // not keep the turn going for new mail.
                let inboxCommand = [ctlPath, "inbox-hook", "--provider", "claude"].map(shellQuote).joined(separator: " ")
                for (hook, command) in [("UserPromptSubmit", inboxCommand), ("PostToolUse", inboxCommand), ("Stop", inboxCommand + " '--report-stop'")] {
                    hooks[hook] = .array((hooks[hook]?.array ?? []) + [.object(["hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .number(5)])])])])
                }
                var launchSettings: [String: JSONValue] = ["hooks": .object(hooks)]
                // Generated suggestions render inside Claude's composer and
                // cannot be distinguished safely from a user draft in plain
                // terminal output. Disable them for delegated Claude sessions;
                // actual composer readiness is checked before each follow-up.
                if session.delegationID != nil,
                   TmuxHost.supportsFollowUp(kind: .claude, version: session.launch.executableVersion) {
                    launchSettings["promptSuggestionEnabled"] = .bool(false)
                }
                let settings = integrationDirectory.appendingPathComponent("settings.json")
                try JSONCoding.encode(JSONValue.object(launchSettings)).write(to: settings, options: .atomic)
                arguments += ["--mcp-config", configPath.path, "--settings", settings.path]
            }
            if !resume, let task = session.initialTask, !task.isEmpty { arguments += ["--", task] }
        }
        return arguments
    }
    /// These string/array literals are passed to Codex's TOML parser. JSON's
    /// optional escaped slash is invalid in a TOML basic string.
    private static func tomlLiteral<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
