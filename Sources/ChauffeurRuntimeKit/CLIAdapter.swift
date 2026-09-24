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

/// Kind-keyed entry points over `ProviderIntegration`. Shells have no integration.
public enum CLIAdapter {
    /// `modelCache` receives models a probing provider lists (`ModelSuggestionCache`).
    public static func capabilities(executable: String, kind: CLIKind, environment: [String: String], modelCache: URL? = nil) async throws -> CLICapabilities {
        if let integration = kind.integration { return try await integration.capabilities(executable: executable, environment: environment, modelCache: modelCache) }
        return try await probe(executable: executable, provider: nil, environment: environment)
    }
    static let unidentifiedLimitation = "The executable does not identify itself as the selected agent. Check the preset executable, or use basic terminal mode"
    struct ProbeOutput { var version: String; var help: String; var helpError: String }
    static func probeOutput(executable: String, environment: [String: String]) async throws -> ProbeOutput {
        let version = try await ProcessRunner.run(executable, ["--version"], environment: environment)
        guard version.status == 0 else { throw ChauffeurError("version_failed", "Executable does not report its version", path: executable) }
        let help = try await ProcessRunner.run(executable, ["--help"], environment: environment)
        guard help.status == 0 else { throw ChauffeurError("help_failed", "Executable does not report its supported options", path: executable) }
        return ProbeOutput(version: version.output.trimmingCharacters(in: .whitespacesAndNewlines), help: help.output, helpError: help.error)
    }
    /// Native CLIs update frequently. Identify the provider without pinning a
    /// release number; feature flags are discovered from native help.
    public static func probe(executable: String, provider: (any AgentProvider)?, environment: [String: String]) async throws -> CLICapabilities {
        let output = try await probeOutput(executable: executable, environment: environment)
        let text = output.version, help = output.help
        let baseline = provider?.identifies(version: text, help: help + "\n" + output.helpError) ?? false
        let delegatedYOLO = provider.map { help.contains($0.autoApprove.flag) } ?? false
        return CLICapabilities(version: String(text.prefix(200)), coordination: baseline, statusSignals: baseline, additionalDirectories: help.contains("--add-dir"), resume: help.contains("resume"), delegatedYOLO: delegatedYOLO, limitation: baseline ? provider?.coordinationLimitation : unidentifiedLimitation)
    }
    public static func identifiesProvider(kind: CLIKind, version: String) -> Bool {
        kind.provider?.identifies(version: version) ?? false
    }

    /// The exact command a coordinator runs in the background to wait for
    /// workers; Claude's launch settings pre-approve it and nothing broader.
    public static func waitCommand(ctlPath: String) -> String {
        let plain = ctlPath.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "/._-+".unicodeScalars.contains($0) }
        return (plain ? ctlPath : shellQuote(ctlPath)) + " wait-for-work"
    }
    public static func codexHookDefinitions(ctlPath: String) -> [CodexHookTrust.Definition] { CodexIntegration.hookDefinitions(ctlPath: ctlPath) }
    public static func codexHookArguments(_ definitions: [CodexHookTrust.Definition]) throws -> [String] { try CodexIntegration.hookArguments(definitions) }

    /// `codexHookTrust` holds the `hooks/list` hashes for Chauffeur's Codex hooks.
    /// Without it, Codex launches with MCP and `notify` only.
    public static func arguments(session: Session, endpoint: String, ctlPath: String, integrationDirectory: URL, coordination: Bool, resume: Bool, codexHookTrust: [String: String]? = nil) throws -> [String] {
        try launch(session: session, endpoint: endpoint, ctlPath: ctlPath, integrationDirectory: integrationDirectory, coordination: coordination, resume: resume, preparation: LaunchPreparation(hookTrust: codexHookTrust)).arguments
    }
    public static func launch(session: Session, endpoint: String, ctlPath: String, integrationDirectory: URL, coordination: Bool, resume: Bool, preparation: LaunchPreparation, pluginPath: String? = nil) throws -> ProviderLaunch {
        let preset = session.launch.preset
        let resolved = try session.launch.resolvedArguments ?? LaunchOptions.resolve(preset: preset).arguments
        try LaunchPolicy.validateArguments(resolved, kind: preset.kind)
        guard let integration = preset.kind.integration else {
            guard !resume else { throw ChauffeurError("resume_unavailable", "Shell sessions cannot be resumed. Open a new shell") }
            return ProviderLaunch(arguments: resolved)
        }
        return try integration.launch(LaunchContext(session: session, userArguments: resolved, endpoint: endpoint, ctlPath: ctlPath, integrationDirectory: integrationDirectory, coordination: coordination, resume: resume, preparation: preparation, pluginPath: pluginPath))
    }
    /// These string/array literals are passed to Codex's TOML parser. JSON's
    /// optional escaped slash is invalid in a TOML basic string.
    static func tomlLiteral<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
