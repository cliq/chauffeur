import ChauffeurCore
import Foundation

public struct CodexConfigurationMigration: ConfigurationMigration {
    public static let supportedCategories: Set<CopyCategory> = [.preferences, .instructions, .reusable, .plugins, .connections]
    public static let defaultCategories: Set<CopyCategory> = [.preferences, .instructions, .reusable]

    public init() {}

    public func preview(pair: SetupAgentPair) throws -> CopyPreview {
        let paths = try MigrationSupport.validatePair(pair)
        guard pair.kind == .codex else { throw ConfigurationMigrationError.invalidPair("This migration adapter only supports Codex.") }
        guard let source = paths.source else {
            let warnings = ["Starting fresh: no source configuration will be copied."]
            return CopyPreview(pairID: pair.id, sourcePath: nil, destinationPath: paths.destination.path, warnings: warnings,
                               selectionDigest: MigrationSupport.selectionDigest(pair: pair, entries: [], warnings: warnings))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationMigrationError.invalidPair("The Codex source folder does not exist.")
        }
        var entries: [CopyEntry] = []
        var warnings: [String] = []
        if pair.categories.contains(.history) { warnings.append("Codex conversation history cannot be copied by this setup flow.") }
        if pair.categories.contains(.hooks) { warnings.append("Codex does not expose a separate hooks category for migration.") }
        if pair.categories.contains(.instructions) { addFile("AGENTS.md", category: .instructions, source: source, entries: &entries, warnings: &warnings) }
        try addConfiguration(source: source, pair: pair, entries: &entries, warnings: &warnings)
        if pair.categories.contains(.reusable) {
            for directory in ["prompts", "rules", "skills"] {
                try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: directory, category: .reusable, into: &entries, warnings: &warnings)
            }
        }
        if pair.categories.contains(.plugins) {
            try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: "plugins", category: .plugins, into: &entries, warnings: &warnings)
        }
        entries.sort { $0.destinationRelativePath.localizedStandardCompare($1.destinationRelativePath) == .orderedAscending }
        let selection = MigrationSupport.selectionDigest(pair: pair, entries: entries, warnings: warnings)
        return CopyPreview(pairID: pair.id, sourcePath: source.path, destinationPath: paths.destination.path,
                           entries: entries, warnings: warnings, selectionDigest: selection)
    }

    public func write(preview: CopyPreview, pair: SetupAgentPair, staging: URL) throws {
        let current = try self.preview(pair: pair)
        try MigrationSupport.verify(preview: preview, against: current)
        try MigrationSupport.write(preview: preview, pair: pair, staging: staging) { entry, data in
            if entry.sourceRelativePath == "config.toml" { return try ConfigurationDocument.codexTOML(data, categories: pair.categories) }
            return data
        }
    }

    private func addConfiguration(
        source: URL, pair: SetupAgentPair, entries: inout [CopyEntry], warnings: inout [String]
    ) throws {
        guard !pair.categories.intersection([.preferences, .connections, .plugins]).isEmpty else { return }
        let url = source.appendingPathComponent("config.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let output = try ConfigurationDocument.codexTOML(data, categories: pair.categories)
            let omitted = try ConfigurationDocument.omittedCodexKeys(data)
            if !omitted.isEmpty { warnings.append("Omitted unsupported or credential-bearing fields from config.toml: \(omitted.joined(separator: ", ")).") }
            guard !String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                warnings.append("Skipped config.toml: none of its supported fields are in the selected categories.")
                return
            }
            let file = try MigrationSupport.digestFile(url)
            let category: CopyCategory = pair.categories.contains(.preferences) ? .preferences
                : pair.categories.contains(.connections) ? .connections : .plugins
            entries.append(CopyEntry(sourceRelativePath: "config.toml", destinationRelativePath: "config.toml", category: category, sourceDigest: file.digest, size: file.size))
        } catch {
            warnings.append("Skipped config.toml: it could not be parsed safely (\(error.localizedDescription)).")
        }
    }

    private func addFile(
        _ name: String, category: CopyCategory, source: URL,
        entries: inout [CopyEntry], warnings: inout [String]
    ) {
        let url = source.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try MigrationSupport.digestFile(url)
            entries.append(CopyEntry(sourceRelativePath: name, destinationRelativePath: name, category: category, sourceDigest: file.digest, size: file.size))
        } catch { warnings.append(error.localizedDescription) }
    }
}
