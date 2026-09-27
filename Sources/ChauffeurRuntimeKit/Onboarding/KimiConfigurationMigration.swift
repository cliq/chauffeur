import Foundation
import ChauffeurCore

/// New profiles can copy portable instructions and skills. Provider config
/// contains credentials, so it is deliberately not copied to a new account.
public struct KimiConfigurationMigration: ConfigurationMigration {
    public init() {}
    public func preview(pair: SetupAgentPair) throws -> CopyPreview {
        guard pair.kind == .kimi else { throw ConfigurationMigrationError.invalidPair("This adapter only supports Kimi Code.") }
        let paths = try MigrationSupport.validatePair(pair)
        var entries: [CopyEntry] = [], warnings: [String] = []
        if let source = paths.source {
            if pair.categories.contains(.instructions), FileManager.default.fileExists(atPath: source.appendingPathComponent("AGENTS.md").path) {
                let file = try MigrationSupport.digestFile(source.appendingPathComponent("AGENTS.md"))
                entries.append(CopyEntry(sourceRelativePath: "AGENTS.md", destinationRelativePath: "AGENTS.md", category: .instructions, sourceDigest: file.digest, size: file.size))
            }
            if pair.categories.contains(.reusable) {
                for folder in ["skills", "agents"] {
                    try MigrationSupport.enumerateFiles(sourceRoot: source, relativeRoot: folder, category: .reusable, into: &entries, warnings: &warnings)
                }
            }
            warnings.append("Kimi provider settings, credentials, plugins and session history are not copied. Sign in or configure providers in the new folder.")
        }
        entries.sort { $0.destinationRelativePath < $1.destinationRelativePath }
        return CopyPreview(pairID: pair.id, sourcePath: paths.source?.path, destinationPath: paths.destination.path, entries: entries, warnings: warnings,
                           selectionDigest: MigrationSupport.selectionDigest(pair: pair, entries: entries, warnings: warnings))
    }
    public func write(preview: CopyPreview, pair: SetupAgentPair, staging: URL) throws {
        try MigrationSupport.verify(preview: preview, against: self.preview(pair: pair))
        try MigrationSupport.write(preview: preview, pair: pair, staging: staging) { _, data in data }
    }
}
