import Foundation
import ChauffeurCore

public struct PiIntegration: ProviderIntegration {
    public init() {}
    public var provider: any AgentProvider { PiProvider() }

    public func capabilities(executable: String, environment: [String: String], modelCache: URL?) async throws -> CLICapabilities {
        let probe = try await CLIAdapter.probeOutput(executable: executable, environment: environment)
        let help = probe.help + "\n" + probe.helpError
        let identified = provider.identifies(version: probe.version, help: help)
        if identified, let modelCache {
            Task.detached { await Self.refreshModels(executable: executable, environment: environment, cache: modelCache) }
        }
        // Pi has unrestricted filesystem tools; additional folders need no grants.
        return CLICapabilities(version: String(probe.version.prefix(200)), coordination: identified, statusSignals: identified,
                               additionalDirectories: identified, resume: identified, delegatedYOLO: identified,
                               limitation: identified ? nil : (help.contains("pi - AI coding assistant")
                                   ? "Pi 0.87.0 or newer is required for coordinated sessions. Update Pi or select basic terminal mode"
                                   : CLIAdapter.unidentifiedLimitation))
    }

    static func refreshModels(executable: String, environment: [String: String], cache: URL) async {
        guard let listed = try? await ProcessRunner.run(executable, ["--offline", "--no-extensions", "--no-skills", "--no-approve", "--list-models"], environment: environment, timeout: 20, outputLimit: 256 * 1024), listed.status == 0 else { return }
        try? ModelSuggestionCache.store(parseModels(listed.output), kind: .pi, executable: executable,
                                        configurationDirectory: environment["PI_CODING_AGENT_DIR"] ?? "", at: cache)
    }

    static func parseModels(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count == 6, ["yes", "no"].contains(columns[4]), ["yes", "no"].contains(columns[5]) else { return nil }
            return "\(columns[0])/\(columns[1])"
        }
    }

    public func publishPlugin(root: URL) throws -> String? {
        let source = try PiPlugin.bundledSource()
        let directory = root.appendingPathComponent("plugins")
        let url = directory.appendingPathComponent(PiPlugin.fileName)
        if (try? Data(contentsOf: url)) != source {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }

    public func launch(_ context: LaunchContext) throws -> ProviderLaunch {
        let session = context.session
        var arguments = context.userArguments
        let identity = context.resume ? try context.resumeID(provider) : session.nativeConversationID ?? session.id.uuidString
        arguments += [context.resume ? "--session" : "--session-id", identity.lowercased()]
        if !session.launch.additionalPaths.isEmpty {
            // These are context, not filesystem restrictions: Pi has no --add-dir.
            let paths = String(decoding: try JSONCoding.encode(session.launch.additionalPaths), as: UTF8.self)
            arguments += ["--append-system-prompt", "Additional working directories selected in Chauffeur (JSON): " + paths]
        }
        if context.coordination {
            guard let pluginPath = context.pluginPath else { throw ChauffeurError("integration_unavailable", "The Pi extension could not be published. Retry or select basic terminal mode") }
            arguments += ["--extension", pluginPath]
        }
        if !context.resume, let task = session.initialTask, !task.isEmpty {
            // Even after --, Pi treats @text as a file attachment. A leading newline
            // preserves the task text while making it an ordinary prompt argument.
            arguments += ["--", task.hasPrefix("@") ? "\n" + task : task]
        }
        return ProviderLaunch(arguments: arguments, environment: context.coordination ? ["CHAUFFEUR_PI_ENDPOINT": context.endpoint] : [:])
    }
}
