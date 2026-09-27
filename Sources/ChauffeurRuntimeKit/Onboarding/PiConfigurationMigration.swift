import Foundation
import ChauffeurCore

/// Copies Pi's portable authored resources. Authentication, model and runtime
/// settings, executable extensions, commands, and session data stay behind.
public struct PiConfigurationMigration: ConfigurationMigration {
    private static let instructionNames: Set<String> = [
        "AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD",
        "SYSTEM.md", "APPEND_SYSTEM.md"
    ]

    public init() {}

    public func preview(pair: SetupAgentPair) throws -> CopyPreview {
        guard pair.kind == .pi else { throw ConfigurationMigrationError.invalidPair("This adapter only supports Pi.") }
        let paths = try MigrationSupport.validatePair(pair)
        var entries: [CopyEntry] = [], warnings: [String] = []
        if let source = paths.source {
            if pair.categories.contains(.instructions) {
                let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
                let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys))
                for url in children where Self.instructionNames.contains(url.lastPathComponent) {
                    let values = try url.resourceValues(forKeys: keys)
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        warnings.append("Skipped \(url.lastPathComponent): Pi instruction files must be regular files.")
                        continue
                    }
                    let file = try MigrationSupport.digestFile(url)
                    entries.append(CopyEntry(sourceRelativePath: url.lastPathComponent, destinationRelativePath: url.lastPathComponent,
                                             category: .instructions, sourceDigest: file.digest, size: file.size))
                }
            }
            if pair.categories.contains(.reusable) {
                for folder in ["skills", "prompts"] {
                    try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: folder, category: .reusable,
                                                        into: &entries, warnings: &warnings)
                }
            }
            if pair.categories.contains(.preferences) {
                try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: "themes", category: .preferences,
                                                    into: &entries, warnings: &warnings)
            }
            warnings.append("Pi credentials, models, settings, extensions, commands and session history are not copied. Open Pi and enter /login in the new folder.")
        }
        entries.sort { $0.destinationRelativePath < $1.destinationRelativePath }
        return CopyPreview(pairID: pair.id, sourcePath: paths.source?.path, destinationPath: paths.destination.path,
                           entries: entries, warnings: warnings,
                           selectionDigest: MigrationSupport.selectionDigest(pair: pair, entries: entries, warnings: warnings))
    }

    public func write(preview: CopyPreview, pair: SetupAgentPair, staging: URL) throws {
        try MigrationSupport.verify(preview: preview, against: self.preview(pair: pair))
        try MigrationSupport.write(preview: preview, pair: pair, staging: staging) { _, data in data }
    }
}
