import Foundation
import Darwin
import ChauffeurCore

public struct KimiIntegration: ProviderIntegration {
    public init() {}
    public var provider: any AgentProvider { KimiProvider() }

    public func capabilities(executable: String, environment: [String: String], modelCache: URL?) async throws -> CLICapabilities {
        let output = try await CLIAdapter.probeOutput(executable: executable, environment: environment)
        let help = output.help + output.helpError
        let identified = provider.identifies(version: output.version, help: help)
        if identified, let modelCache,
           let result = try? await ProcessRunner.run(executable, ["provider", "list", "--json"], environment: environment, timeout: 8, outputLimit: 256 * 1024), result.status == 0,
           let value = try? JSONCoding.decode(JSONValue.self, from: Data(result.output.utf8)), case .object(let models) = value["models"] {
            try? ModelSuggestionCache.store(models.keys.sorted(), kind: .kimi, executable: executable, configurationDirectory: environment["KIMI_CODE_HOME"] ?? "", at: modelCache)
        }
        return CLICapabilities(version: output.version, coordination: identified, statusSignals: identified,
                               additionalDirectories: help.contains("--add-dir"), resume: identified && help.contains("--session"),
                               delegatedYOLO: identified && help.contains("--auto"), limitation: identified ? nil : CLIAdapter.unidentifiedLimitation)
    }

    public func launch(_ context: LaunchContext) throws -> ProviderLaunch {
        var arguments = context.userArguments
        if context.resume { arguments += ["--session", try context.resumeID(provider)] }
        for path in context.session.launch.additionalPaths { arguments += ["--add-dir", path] }
        if context.coordination {
            try installPlugin(home: URL(fileURLWithPath: context.session.launch.configurationPath), ctlPath: context.ctlPath)
        }
        // The runtime supplies the session token after resolving the coordinated launch.
        return ProviderLaunch(arguments: arguments, environment: context.coordination ? ["CHAUFFEUR_KIMI_ENDPOINT": context.endpoint] : [:])
    }

    /// The CLI has no per-invocation MCP/hook options. The shared plugin contains
    /// only a helper path and environment references, never a session ID or token.
    /// A file lock serializes Chauffeur launches that share this Kimi home.
    static func manifest(ctlPath: String) -> [String: Any] {
        let guardCommand = "if [ -n \"${CHAUFFEUR_KIMI_TOKEN:-}\" ]; then exec \"${CHAUFFEUR_CTL}\" "
        var hooks: [[String: Any]] = []
        for (event, status) in [("SessionStart", "session-start"), ("TurnStarted", "running"), ("PostToolUse", "running"), ("Stop", "turn-finished"), ("PermissionRequest", "needs-attention"),
                                ("PermissionResult", "running"), ("StopFailure", "needs-attention"), ("Interrupt", "turn-finished")] {
            hooks.append(["event": event, "command": guardCommand + "event " + status + "; fi", "timeout": 5])
        }
        // Kimi does not re-emit Stop after a hook continuation, and ignores
        // PostToolUse output. Only prompt hooks claim reminders; idle results
        // wake coordinators through the runtime after normal Stop completion.
        for event in ["UserPromptSubmit"] {
            hooks.append(["event": event, "command": guardCommand + "inbox-hook --provider kimi --report-running; fi", "timeout": 5])
        }
        return ["name": "chauffeur", "version": "1.0.0", "description": "Chauffeur session coordination",
                "hooks": hooks, "mcpServers": ["chauffeur": ["transport": "stdio", "command": "sh", "args": ["-c", "exec " + CLIAdapter.shellQuote(ctlPath) + " kimi-mcp"], "toolTimeoutMs": 360_000]]]
    }

    func installPlugin(home: URL, ctlPath: String) throws {
        let manager = FileManager.default
        let plugins = home.appendingPathComponent("plugins")
        try manager.createDirectory(at: plugins, withIntermediateDirectories: true)
        let lock = open(plugins.appendingPathComponent(".chauffeur.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ChauffeurError("kimi_plugin", "Cannot lock Kimi's plugin registry") }
        defer { flock(lock, LOCK_UN); close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw ChauffeurError("kimi_plugin", "Cannot lock Kimi's plugin registry") }
        let registry = plugins.appendingPathComponent("installed.json")
        var document: [String: Any] = ["version": 1, "plugins": [[String: Any]]()]
        if manager.fileExists(atPath: registry.path) {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: registry)) as? [String: Any],
                  parsed["version"] as? Int == 1, parsed["plugins"] is [[String: Any]] else {
                throw ChauffeurError("kimi_plugin", "Kimi's plugin registry is unrecognized; it was preserved")
            }
            document = parsed
        }
        var records = document["plugins"] as! [[String: Any]]
        let root = plugins.appendingPathComponent("managed/chauffeur")
        if let existing = records.first(where: { $0["id"] as? String == "chauffeur" }) {
            guard existing["root"] as? String == root.path, existing["enabled"] as? Bool == true else {
                throw ChauffeurError("kimi_plugin", "The Chauffeur plugin is disabled or its name is in use. Check Kimi's /plugins before enabling coordination")
            }
        } else {
            guard !manager.fileExists(atPath: root.path) else { throw ChauffeurError("kimi_plugin", "An unregistered Chauffeur plugin folder already exists; it was preserved", path: root.path) }
            records.append(["id": "chauffeur", "root": root.path, "source": "local-path", "enabled": true,
                            "installedAt": ISO8601DateFormatter().string(from: Date())])
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: Self.manifest(ctlPath: ctlPath), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: root.appendingPathComponent("kimi.plugin.json"), options: .atomic)
        document["plugins"] = records
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: registry, options: .atomic)
    }
}
