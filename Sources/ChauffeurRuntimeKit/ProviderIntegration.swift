import Foundation
import ChauffeurCore

/// What a coordinated launch resolved before its arguments are built.
public struct LaunchPreparation: Sendable, Equatable {
    public var inboxReminders: Bool
    /// `hooks/list` hashes for Chauffeur's Codex hooks.
    public var hookTrust: [String: String]?
    /// Reported without failing the launch.
    public var warning: ChauffeurError?
    public init(inboxReminders: Bool = true, hookTrust: [String: String]? = nil, warning: ChauffeurError? = nil) {
        self.inboxReminders = inboxReminders; self.hookTrust = hookTrust; self.warning = warning
    }
}

public struct LaunchContext: Sendable {
    public var session: Session
    /// Resolved and validated preset arguments; the provider appends its own.
    public var userArguments: [String]
    public var endpoint: String
    public var ctlPath: String
    public var integrationDirectory: URL
    public var coordination: Bool
    public var resume: Bool
    public var preparation: LaunchPreparation

    /// The recorded native conversation, checked against the provider's ID shape.
    func resumeID(_ provider: any AgentProvider) throws -> String {
        guard let id = session.nativeConversationID, provider.validatesConversationID(id) else { throw ChauffeurError("resume_unavailable", "No native conversation ID was recorded") }
        return id
    }
}

/// A native command line plus the variables it needs beyond the launch environment.
public struct ProviderLaunch: Sendable, Equatable {
    public var arguments: [String]
    public var environment: [String: String]
    public init(arguments: [String], environment: [String: String] = [:]) { self.arguments = arguments; self.environment = environment }
}

/// The I/O half of a provider: probing the executable, preparing and building launches.
public protocol ProviderIntegration: Sendable {
    var provider: any AgentProvider { get }
    func capabilities(executable: String, environment: [String: String]) async throws -> CLICapabilities
    /// Runs once per coordinated launch or resume, before `launch`.
    func prepareLaunch(session: Session, ctlPath: String, environment: [String: String], cacheDirectory: URL) async -> LaunchPreparation
    /// Builds the command line and writes any per-launch files into `integrationDirectory`.
    func launch(_ context: LaunchContext) throws -> ProviderLaunch
    /// Shown while a coordinated session runs without inbox reminders.
    var inboxReminderLimitation: String? { get }
}

public extension ProviderIntegration {
    func capabilities(executable: String, environment: [String: String]) async throws -> CLICapabilities {
        try await CLIAdapter.probe(executable: executable, provider: provider, environment: environment)
    }
    func prepareLaunch(session: Session, ctlPath: String, environment: [String: String], cacheDirectory: URL) async -> LaunchPreparation { LaunchPreparation() }
    var inboxReminderLimitation: String? { nil }
}

public enum ProviderIntegrations {
    public static let all: [any ProviderIntegration] = [CodexIntegration(), ClaudeIntegration()]
}

public extension CLIKind {
    /// nil for `.shell`.
    var integration: (any ProviderIntegration)? { ProviderIntegrations.all.first { $0.provider.kind == self } }
}

public struct ClaudeIntegration: ProviderIntegration {
    public init() {}
    public var provider: any AgentProvider { ClaudeProvider() }

    public func launch(_ context: LaunchContext) throws -> ProviderLaunch {
        let session = context.session, ctlPath = context.ctlPath, directory = context.integrationDirectory
        var arguments = context.userArguments
        if context.resume { arguments += ["--resume", try context.resumeID(provider)] }
        else { arguments += ["--session-id", session.nativeConversationID ?? session.id.uuidString] }
        for path in session.launch.additionalPaths { arguments += ["--add-dir", path] }
        if context.coordination {
            let config: JSONValue = .object(["mcpServers": .object(["chauffeur": .object([
                "type": .string("http"), "url": .string(context.endpoint), "timeout": .number(360_000),
                "headers": .object(["Authorization": .string("Bearer ${CHAUFFEUR_SESSION_TOKEN}")])
            ])])])
            let configPath = directory.appendingPathComponent("mcp.json")
            try JSONCoding.encode(config).write(to: configPath, options: .atomic)
            var hooks: [String: JSONValue] = [:]
            for (hook, event) in [("SessionStart", "running"), ("UserPromptSubmit", "running"),
                                  ("PostToolUse", "running"), ("PostToolUseFailure", "running"),
                                  ("StopFailure", "needs-attention"),
                                  ("Notification", "needs-attention"), ("PermissionRequest", "needs-attention")] {
                let command = [ctlPath, "event", "--session", session.id.uuidString, event].map(CLIAdapter.shellQuote).joined(separator: " ")
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
            let inboxCommand = [ctlPath, "inbox-hook", "--provider", "claude"].map(CLIAdapter.shellQuote).joined(separator: " ")
            for (hook, command) in [("UserPromptSubmit", inboxCommand), ("PostToolUse", inboxCommand), ("Stop", inboxCommand + " '--report-stop'")] {
                hooks[hook] = .array((hooks[hook]?.array ?? []) + [.object(["hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .number(5)])])])])
            }
            var launchSettings: [String: JSONValue] = ["hooks": .object(hooks),
                "permissions": .object(["allow": .array([.string("Bash(\(CLIAdapter.waitCommand(ctlPath: ctlPath)):*)")])])]
            // Generated suggestions render inside Claude's composer and
            // cannot be distinguished safely from a user draft in plain
            // terminal output. Disable them for delegated Claude sessions;
            // actual composer readiness is checked before each follow-up.
            if session.delegationID != nil, provider.identifies(version: session.launch.executableVersion) {
                launchSettings["promptSuggestionEnabled"] = .bool(false)
            }
            let settings = directory.appendingPathComponent("settings.json")
            try JSONCoding.encode(JSONValue.object(launchSettings)).write(to: settings, options: .atomic)
            arguments += ["--mcp-config", configPath.path, "--settings", settings.path]
        }
        if !context.resume, let task = session.initialTask, !task.isEmpty { arguments += ["--", task] }
        return ProviderLaunch(arguments: arguments)
    }
}

public struct CodexIntegration: ProviderIntegration {
    public init() {}
    public var provider: any AgentProvider { CodexProvider() }
    public var inboxReminderLimitation: String? { CodexHookTrust.unavailableMessage }

    /// Hooks Chauffeur adds for a coordinated session. The commands carry no
    /// session ID (the session comes from `CHAUFFEUR_SESSION_TOKEN`), so their
    /// trust hashes stay the same across sessions.
    public static func hookDefinitions(ctlPath: String) -> [CodexHookTrust.Definition] {
        // Codex status otherwise comes only from notify at the end of a turn.
        let inbox = [ctlPath, "inbox-hook", "--provider", "codex", "--report-running"].map(CLIAdapter.shellQuote).joined(separator: " ")
        return [CodexHookTrust.Definition(event: "SessionStart", command: [ctlPath, "event", "session-start"].map(CLIAdapter.shellQuote).joined(separator: " "))]
            + ["UserPromptSubmit", "PostToolUse", "Stop"].map { CodexHookTrust.Definition(event: $0, command: inbox) }
    }
    public static func hookArguments(_ definitions: [CodexHookTrust.Definition]) throws -> [String] {
        try definitions.flatMap { ["-c", "hooks.\($0.event)=[{hooks=[{type=\"command\",command=\(try CLIAdapter.tomlLiteral($0.command)),timeout=5}]}]"] }
    }

    /// Hashes that let this launch trust Chauffeur's own hooks. Without them the
    /// launch has MCP and notify only, and no inbox reminders.
    public func prepareLaunch(session: Session, ctlPath: String, environment: [String: String], cacheDirectory: URL) async -> LaunchPreparation {
        let definitions = Self.hookDefinitions(ctlPath: ctlPath)
        guard let arguments = try? Self.hookArguments(definitions) else { return LaunchPreparation(inboxReminders: false) }
        guard let hashes = await CodexHookTrust.resolve(executable: session.launch.executablePath, version: session.launch.executableVersion, hookArguments: arguments, expected: definitions, environment: environment, cacheDirectory: cacheDirectory) else {
            return LaunchPreparation(inboxReminders: false, warning: ChauffeurError("integration_unavailable", CodexHookTrust.unavailableMessage))
        }
        return LaunchPreparation(inboxReminders: true, hookTrust: hashes)
    }

    public func launch(_ context: LaunchContext) throws -> ProviderLaunch {
        let session = context.session, ctlPath = context.ctlPath
        var arguments = context.userArguments + ["-C", session.launch.workingDirectory]
        for path in session.launch.additionalPaths { arguments += ["--add-dir", path] }
        if context.coordination {
            arguments += ["-c", "mcp_servers.chauffeur.url=\(try CLIAdapter.tomlLiteral(context.endpoint))", "-c", "mcp_servers.chauffeur.bearer_token_env_var=\(try CLIAdapter.tomlLiteral("CHAUFFEUR_SESSION_TOKEN"))"]
            arguments += ["-c", "mcp_servers.chauffeur.tool_timeout_sec=360"]
            let notify = [ctlPath, "event", "--session", session.id.uuidString, "turn-finished"]
            arguments += ["-c", "notify=\(try CLIAdapter.tomlLiteral(notify))"]
            // A blocking Stop is not the end of a turn, so status still comes from notify.
            if let trust = context.preparation.hookTrust {
                arguments += try Self.hookArguments(Self.hookDefinitions(ctlPath: ctlPath))
                arguments += ["-c", try CodexHookTrust.stateArgument(trust)]
            }
        }
        if context.resume { arguments += ["resume", try context.resumeID(provider)] }
        else if let task = session.initialTask, !task.isEmpty { arguments += ["--", task] }
        return ProviderLaunch(arguments: arguments)
    }
}
