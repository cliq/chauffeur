import ChauffeurCore
import Foundation

/// A team's OpenCode folder is an extra layer over `~/.config/opencode`, which
/// still loads. Copying from it would load its plugins and agents twice (V9).
public struct OpenCodeConfigurationMigration: ConfigurationMigration {
    public init() {}

    public func preview(pair: SetupAgentPair) throws -> CopyPreview {
        guard pair.kind == .opencode else { throw ConfigurationMigrationError.invalidPair("This migration adapter only supports OpenCode.") }
        var fresh = pair; fresh.sourcePath = nil
        let paths = try MigrationSupport.validatePair(fresh)
        return CopyPreview(pairID: pair.id, sourcePath: nil, destinationPath: paths.destination.path,
                           selectionDigest: MigrationSupport.selectionDigest(pair: fresh, entries: [], warnings: []))
    }

    public func write(preview: CopyPreview, pair: SetupAgentPair, staging: URL) throws {
        try MigrationSupport.verify(preview: preview, against: self.preview(pair: pair))
    }
}
