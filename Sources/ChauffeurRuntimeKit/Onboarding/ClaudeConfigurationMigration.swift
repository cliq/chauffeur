import ChauffeurCore
import Foundation

public struct ClaudeConfigurationMigration: ConfigurationMigration {
    public static let supportedCategories: Set<CopyCategory> = [.preferences, .instructions, .reusable, .plugins, .connections, .hooks, .history]
    public static let defaultCategories: Set<CopyCategory> = [.preferences, .instructions, .reusable]

    private let homeDirectory: URL

    public init() {
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    init(homeDirectory: URL) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func availableProjects(sourcePath: String) throws -> [String] {
        let source = URL(fileURLWithPath: Paths.canonical(sourcePath)).standardizedFileURL
        let root = source.appendingPathComponent("projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
        ).filter {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }.map(\.path).sorted()
    }

    public func preview(pair: SetupAgentPair) throws -> CopyPreview {
        let paths = try MigrationSupport.validatePair(pair)
        guard pair.kind == .claude else { throw ConfigurationMigrationError.invalidPair("This migration adapter only supports Claude Code.") }
        guard let source = paths.source else {
            let warnings = ["Starting fresh: no source configuration will be copied."]
            return CopyPreview(pairID: pair.id, sourcePath: nil, destinationPath: paths.destination.path, warnings: warnings,
                               selectionDigest: MigrationSupport.selectionDigest(pair: pair, entries: [], warnings: warnings))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigurationMigrationError.invalidPair("The Claude source folder does not exist.")
        }

        var entries: [CopyEntry] = []
        var warnings: [String] = []
        if pair.categories.contains(.instructions) { try addFile("CLAUDE.md", category: .instructions, source: source, pair: pair, entries: &entries, warnings: &warnings) }
        for name in ["settings.json", "settings.local.json", ".mcp.json"] {
            try addSettings(name, source: source, pair: pair, entries: &entries, warnings: &warnings)
        }
        try addUserConfiguration(source: source, pair: pair, entries: &entries, warnings: &warnings)
        if pair.categories.contains(.reusable) {
            for directory in ["skills", "commands", "agents", "rules"] {
                try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: directory, category: .reusable, into: &entries, warnings: &warnings)
            }
        }
        if pair.categories.contains(.plugins) {
            try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: "plugins", category: .plugins, into: &entries, warnings: &warnings)
        }
        if pair.categories.contains(.history) {
            for directory in ["todos", "tasks"] {
                try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: directory, category: .history, into: &entries, warnings: &warnings)
            }
            try addProjects(source: source, pair: pair, entries: &entries, warnings: &warnings)
        }
        entries.sort { $0.destinationRelativePath.localizedStandardCompare($1.destinationRelativePath) == .orderedAscending }
        let selection = MigrationSupport.selectionDigest(pair: pair, entries: entries, warnings: warnings)
        return CopyPreview(pairID: pair.id, sourcePath: source.path, destinationPath: paths.destination.path,
                           entries: entries, warnings: warnings, selectionDigest: selection,
                           availableProjects: try availableProjects(sourcePath: source.path))
    }

    public func write(preview: CopyPreview, pair: SetupAgentPair, staging: URL) throws {
        let current = try self.preview(pair: pair)
        try MigrationSupport.verify(preview: preview, against: current)
        let sources = [pair.sourcePath, current.sourcePath].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        let destination = URL(fileURLWithPath: current.destinationPath)
        if let accountEntry = preview.entries.first(where: { $0.sourceRelativePath == ".claude.json" }) {
            try writeUserConfiguration(entry: accountEntry, source: URL(fileURLWithPath: current.sourcePath!),
                                       staging: staging)
        }
        var regularPreview = preview
        regularPreview.entries.removeAll { $0.sourceRelativePath == ".claude.json" }
        try MigrationSupport.write(preview: regularPreview, pair: pair, staging: staging) { entry, data in
            if ["settings.json", "settings.local.json", ".mcp.json"].contains(entry.sourceRelativePath) {
                return try ConfigurationDocument.claudeJSON(data, categories: pair.categories)
            }
            let pluginMetadata = ["known_marketplaces.json", "installed_plugins.json", "config.json"]
            if entry.sourceRelativePath.hasPrefix("plugins/"), pluginMetadata.contains(URL(fileURLWithPath: entry.sourceRelativePath).lastPathComponent) {
                return try sources.reduce(data) { value, source in
                    try ConfigurationDocument.repairPluginJSON(value, source: source, destination: destination)
                }
            }
            return data
        }
    }

    private func addSettings(
        _ name: String, source: URL, pair: SetupAgentPair,
        entries: inout [CopyEntry], warnings: inout [String]
    ) throws {
        guard !pair.categories.intersection([.preferences, .hooks, .connections, .plugins]).isEmpty else { return }
        let url = source.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let sanitized = try ConfigurationDocument.sanitizedClaudeJSON(data, categories: pair.categories)
            try appendDocumentWarnings(name: name, sanitized: sanitized, source: source, warnings: &warnings)
            let object = try JSONSerialization.jsonObject(with: sanitized.data) as? [String: Any]
            guard object?.isEmpty == false else {
                warnings.append("Skipped \(name): none of its supported fields are in the selected categories.")
                return
            }
            let file = try MigrationSupport.digestFile(url)
            let category: CopyCategory = pair.categories.contains(.preferences) ? .preferences
                : pair.categories.contains(.hooks) ? .hooks
                : pair.categories.contains(.connections) ? .connections : .plugins
            entries.append(CopyEntry(sourceRelativePath: name, destinationRelativePath: name, category: category, sourceDigest: file.digest, size: file.size))
        } catch {
            warnings.append("Skipped \(name): it could not be parsed safely (\(error.localizedDescription)).")
        }
    }

    private func addUserConfiguration(
        source: URL, pair: SetupAgentPair, entries: inout [CopyEntry], warnings: inout [String]
    ) throws {
        guard pair.categories.contains(.connections), let url = userConfigurationURL(source: source) else { return }
        do {
            if !url.path.hasPrefix(source.path + "/") {
                warnings.append("The default Claude .claude.json is outside the selected source folder; only its sanitized MCP server configuration will be imported.")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let sanitized = try ConfigurationDocument.sanitizedClaudeJSON(data, categories: [.connections])
            try appendDocumentWarnings(name: ".claude.json", sanitized: sanitized, source: source, warnings: &warnings)
            let object = try JSONSerialization.jsonObject(with: sanitized.data) as? [String: Any]
            guard object?["mcpServers"] != nil || object?["mcp"] != nil else {
                warnings.append("Skipped .claude.json: it has no supported MCP server configuration.")
                return
            }
            entries.append(CopyEntry(sourceRelativePath: ".claude.json", destinationRelativePath: ".claude.json",
                                     category: .connections, sourceDigest: MigrationSupport.digest(sanitized.data),
                                     size: Int64(sanitized.data.count)))
        } catch {
            warnings.append("Skipped .claude.json: it could not be parsed safely (\(error.localizedDescription)).")
        }
    }

    private func writeUserConfiguration(entry: CopyEntry, source: URL, staging: URL) throws {
        guard let url = userConfigurationURL(source: source) else {
            throw ConfigurationMigrationError.sourceChanged("The selected Claude user configuration is no longer available.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let sanitized = try ConfigurationDocument.sanitizedClaudeJSON(data, categories: [.connections])
        guard MigrationSupport.digest(sanitized.data) == entry.sourceDigest else {
            throw ConfigurationMigrationError.sourceChanged("The selected MCP configuration changed after preview: .claude.json")
        }
        let destination = staging.appendingPathComponent(".claude.json")
        do {
            try sanitized.data.write(to: destination, options: [.withoutOverwriting])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            throw ConfigurationMigrationError.unsafePath("Cannot create .claude.json in staging.")
        }
    }

    private func userConfigurationURL(source: URL) -> URL? {
        let contained = source.appendingPathComponent(".claude.json").standardizedFileURL
        if isSafeRegularFile(contained) { return contained }
        let defaultDirectory = homeDirectory.appendingPathComponent(".claude").standardizedFileURL
        guard source.standardizedFileURL == defaultDirectory else { return nil }
        let sibling = defaultDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json").standardizedFileURL
        return isSafeRegularFile(sibling) ? sibling : nil
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func appendDocumentWarnings(
        name: String, sanitized: ConfigurationDocument.SanitizedDocument, source: URL, warnings: inout [String]
    ) throws {
        if !sanitized.omittedPaths.isEmpty {
            warnings.append("Omitted unsupported, unselected, or credential-bearing fields from \(name): \(sanitized.omittedPaths.joined(separator: ", ")).")
        }
        let references = try ConfigurationDocument.claudeAbsoluteReferences(sanitized.data, sourcePath: source.path)
        if !references.isEmpty {
            warnings.append("Retained absolute source-folder references in \(name): \(references.joined(separator: ", ")). Referenced files are not copied automatically.")
        }
    }

    private func addFile(
        _ name: String, category: CopyCategory, source: URL, pair: SetupAgentPair,
        entries: inout [CopyEntry], warnings: inout [String]
    ) throws {
        let lower = name.lowercased()
        guard !MigrationSupport.credentialNames.contains(lower) else { return }
        let url = source.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try MigrationSupport.digestFile(url)
            entries.append(CopyEntry(sourceRelativePath: name, destinationRelativePath: name, category: category, sourceDigest: file.digest, size: file.size))
        } catch { warnings.append(error.localizedDescription) }
    }

    private func addProjects(
        source: URL, pair: SetupAgentPair, entries: inout [CopyEntry], warnings: inout [String]
    ) throws {
        let projects = source.appendingPathComponent("projects", isDirectory: true).standardizedFileURL
        for selection in pair.projectPaths.sorted() {
            let selected = URL(fileURLWithPath: Paths.canonical(selection)).standardizedFileURL
            guard selected.path.hasPrefix(projects.path + "/"), selected.deletingLastPathComponent().path == projects.path else {
                warnings.append("Skipped project \(selection): choose a direct project folder from \(projects.path).")
                continue
            }
            let relative = "projects/\(selected.lastPathComponent)"
            try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: relative, category: .history, into: &entries, warnings: &warnings)
        }
        if pair.projectPaths.isEmpty, FileManager.default.fileExists(atPath: projects.path) {
            warnings.append("Claude project history is available, but no project folders were selected.")
        }
    }
}
