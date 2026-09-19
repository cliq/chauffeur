import ChauffeurCore
import Foundation
import Testing
@testable import ChauffeurRuntimeKit

struct ConfigurationAssetCopyTests {
    @Test func codexPreservesLegitimateAssetNamesAndLockfilesWhileExcludingCredentialFiles() throws {
        try assertAssetCopy(kind: .codex, migration: CodexConfigurationMigration())
    }

    @Test func claudePreservesLegitimateAssetNamesAndLockfilesWhileExcludingCredentialFiles() throws {
        try assertAssetCopy(kind: .claude, migration: ClaudeConfigurationMigration())
    }

    @Test func sourceRootTransientStateHasADistinctWarningFromCredentials() throws {
        let root = try fixture("warnings")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try write("transient", to: source.appendingPathComponent("logs/runtime.log"))

        var entries: [CopyEntry] = []
        var warnings: [String] = []
        try MigrationSupport.enumerateFiles(
            sourceRoot: source, relativeRoot: "logs", category: .plugins,
            into: &entries, warnings: &warnings
        )

        #expect(entries.isEmpty)
        #expect(warnings.contains { $0.contains("source-root transient state") })
        #expect(!warnings.contains { $0.contains("credentials are not copied") })
    }

    private func assertAssetCopy(kind: CLIKind, migration: any ConfigurationMigration) throws {
        let root = try fixture(kind.rawValue)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let staging = root.appendingPathComponent("stage")
        let destination = root.appendingPathComponent("destination")
        let preserved = [
            "skills/auth/SKILL.md",
            "skills/tokens/SKILL.md",
            "skills/credentials/SKILL.md",
            "skills/auth.json/SKILL.md",
            "skills/debug/SKILL.md",
            "skills/ok/bun.lock",
            "plugins/repos/x/logs/content.txt",
            "plugins/tmp/tool.lock"
        ]
        for path in preserved {
            try write("preserved: \(path)", to: source.appendingPathComponent(path))
        }
        let excluded = [
            "skills/auth/auth.json",
            "skills/debug/.env.local",
            "plugins/repos/x/logs/tokens.json"
        ]
        for path in excluded {
            try write("fixture-secret", to: source.appendingPathComponent(path))
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let pair = SetupAgentPair(
            kind: kind, choice: .create, sourcePath: source.path,
            destinationPath: destination.path, categories: [.reusable, .plugins]
        )
        let preview = try migration.preview(pair: pair)
        let selected = Set(preview.entries.map(\.sourceRelativePath))
        for path in preserved { #expect(selected.contains(path)) }
        for path in excluded { #expect(!selected.contains(path)) }
        #expect(preview.warnings.contains { $0.contains("credentials are not copied") })
        #expect(!preview.warnings.contains { $0.contains("source-root transient state") })

        try migration.write(preview: preview, pair: pair, staging: staging)
        for path in preserved {
            #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent(path).path))
        }
        for path in excluded {
            #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent(path).path))
        }
    }

    private func fixture(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("chauffeur-asset-copy-\(label)-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }
}
