import Foundation
import ChauffeurCore

public struct CLICapabilities: Codable, Sendable {
    public var version: String
    public var coordination: Bool
    public var statusSignals: Bool
    public var additionalDirectories: Bool
    public var resume: Bool
    public var limitation: String?
}

public enum CLIAdapter {
    public static func capabilities(executable: String, kind: CLIKind, environment: [String: String]) async throws -> CLICapabilities {
        let version = try await ProcessRunner.run(executable, ["--version"], environment: environment)
        guard version.status == 0 else { throw ChauffeurError("version_failed", "Executable does not report its version", path: executable) }
        let help = try await ProcessRunner.run(executable, ["--help"], environment: environment)
        guard help.status == 0 else { throw ChauffeurError("help_failed", "Executable does not report its supported options", path: executable) }
        let text = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseline = kind == .codex ? text == "codex-cli 0.154.0" : ["2.1.272 (Claude Code)", "2.1.273 (Claude Code)"].contains(text)
        return CLICapabilities(version: String(text.prefix(200)), coordination: baseline, statusSignals: baseline, additionalDirectories: help.output.contains("--add-dir"), resume: help.output.contains("resume"), limitation: baseline ? (kind == .codex ? "Turn completion via notify; approval/input detection is unavailable" : nil) : "CLI version has not passed coordination/status compatibility checks. Basic terminal mode remains available")
    }
    public static func arguments(session: Session, endpoint: String, ctlPath: String, integrationDirectory: URL, coordination: Bool, resume: Bool) throws -> [String] {
        let preset = session.launch.preset
        try LaunchPolicy.validateArguments(preset.arguments, kind: preset.kind)
        var arguments = preset.arguments
        switch preset.kind {
        case .shell:
            guard !resume else { throw ChauffeurError("resume_unavailable", "Shell sessions cannot be resumed. Open a new shell") }
        case .codex:
            arguments += ["-C", session.launch.workingDirectory]
            for path in session.launch.additionalPaths { arguments += ["--add-dir", path] }
            if coordination {
                arguments += ["-c", "mcp_servers.chauffeur.url=\(try tomlLiteral(endpoint))", "-c", "mcp_servers.chauffeur.bearer_token_env_var=\(try tomlLiteral("CHAUFFEUR_SESSION_TOKEN"))"]
                let notify = [ctlPath, "event", "--session", session.id.uuidString, "turn-finished"]
                arguments += ["-c", "notify=\(try tomlLiteral(notify))"]
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
                    "type": .string("http"), "url": .string(endpoint),
                    "headers": .object(["Authorization": .string("Bearer ${CHAUFFEUR_SESSION_TOKEN}")])
                ])])])
                let configPath = integrationDirectory.appendingPathComponent("mcp.json")
                try JSONCoding.encode(config).write(to: configPath, options: .atomic)
                var hooks: [String: JSONValue] = [:]
                for (hook, event) in [("SessionStart", "running"), ("UserPromptSubmit", "running"),
                                      ("PostToolUse", "running"), ("PostToolUseFailure", "running"),
                                      ("Stop", "turn-finished"), ("StopFailure", "needs-attention"),
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
                let settings = integrationDirectory.appendingPathComponent("settings.json")
                try JSONCoding.encode(JSONValue.object(["hooks": .object(hooks)])).write(to: settings, options: .atomic)
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
