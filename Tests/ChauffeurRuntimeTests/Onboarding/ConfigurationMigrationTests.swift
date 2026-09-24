import ChauffeurCore
import Foundation
import Testing
@testable import ChauffeurRuntimeKit

struct ConfigurationMigrationTests {
    @Test func codexProfileCannotBypassUncheckedConnectionAndPluginCategories() throws {
        let source = Data("""
        [profiles.work]
        model = "fixture-model"
        notify = ["fixture-notify"]
        [profiles.work.mcp_servers.private]
        command = "fixture-mcp"
        [profiles.work.plugins]
        name = "fixture-plugin"
        """.utf8)
        let output = String(decoding: try ConfigurationDocument.codexTOML(source, categories: [.preferences]), as: UTF8.self)
        #expect(output.contains("fixture-model"))
        #expect(!output.contains("fixture-mcp"))
        #expect(!output.contains("fixture-plugin"))
        #expect(!output.contains("fixture-notify"))
    }
    @Test func nestedCredentialsAndLinksAreExcludedButPluginManifestsAndExecutableScriptsSurvive() throws {
        let root = try fixture("nested"); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), stage = root.appendingPathComponent("stage")
        let plugin = source.appendingPathComponent("plugins/example")
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("fixture-secret".utf8).write(to: plugin.appendingPathComponent("credentials.json"))
        try Data("{}".utf8).write(to: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: plugin.appendingPathComponent("run.sh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plugin.appendingPathComponent("run.sh").path)
        try FileManager.default.createSymbolicLink(at: plugin.appendingPathComponent("alias"), withDestinationURL: plugin.appendingPathComponent("credentials.json"))
        let pair = SetupAgentPair(kind: .claude, choice: .create, sourcePath: source.path,
            destinationPath: root.appendingPathComponent("destination").path, categories: [.plugins])
        let adapter = ClaudeConfigurationMigration(), preview = try adapter.preview(pair: pair)
        #expect(!preview.entries.contains { $0.sourceRelativePath.contains("credentials") || $0.sourceRelativePath.hasSuffix("/alias") })
        #expect(preview.entries.contains { $0.sourceRelativePath.hasSuffix(".claude-plugin/plugin.json") })
        try adapter.write(preview: preview, pair: pair, staging: stage)
        #expect(FileManager.default.isExecutableFile(atPath: stage.appendingPathComponent("plugins/example/run.sh").path))
        #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("plugins/example/credentials.json").path))
    }
    @Test func openCodeLayersCopyNothingEvenWithASource() throws {
        let root = try fixture("opencode"); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("opencode"), stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("opencode.json"))
        try Data("export {}".utf8).write(to: source.appendingPathComponent("plugins/a.js"))
        let pair = SetupAgentPair(kind: .opencode, choice: .create, sourcePath: source.path,
            destinationPath: root.appendingPathComponent("opencode-work").path, categories: Set(CopyCategory.allCases))
        let adapter = OpenCodeConfigurationMigration(), preview = try adapter.preview(pair: pair)
        #expect(preview.entries.isEmpty)
        #expect(preview.sourcePath == nil)
        try adapter.write(preview: preview, pair: pair, staging: stage)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stage.path).isEmpty)
        var codex = pair; codex.kind = .codex
        #expect(throws: ConfigurationMigrationError.self) { try adapter.preview(pair: codex) }
    }
    private func fixture(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-migration-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func preferenceCopyExcludesHooksAndCredentials() throws {
        let input = Data(#"{"model":"sonnet","hooks":{"Stop":[]},"env":{"ANTHROPIC_API_KEY":"fixture-secret"}}"#.utf8)
        let output = try ConfigurationDocument.claudeJSON(input, categories: [.preferences])
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("sonnet"))
        #expect(!text.contains("hooks"))
        #expect(!text.contains("fixture-secret"))
    }

    @Test func codexTOMLIsStructurallyPartitionedAndSanitized() throws {
        let input = Data("""
        model = "gpt-5"
        api_key = "fixture-secret"
        [mcp_servers.docs]
        command = "docs"
        token = "nested-secret"
        [history]
        persistence = "save-all"
        """.utf8)
        let preferences = String(decoding: try ConfigurationDocument.codexTOML(input, categories: [.preferences]), as: UTF8.self)
        #expect(preferences.contains("gpt-5"))
        #expect(!preferences.contains("fixture-secret"))
        #expect(!preferences.contains("mcp_servers"))
        #expect(!preferences.contains("history"))
        let connections = String(decoding: try ConfigurationDocument.codexTOML(input, categories: [.connections]), as: UTF8.self)
        #expect(connections.contains("mcp_servers"))
        #expect(connections.contains("docs"))
        #expect(!connections.contains("nested-secret"))
    }

    @Test func claudePreviewWritesSelectedAssetsAndRepairsOnlyPluginPathFields() throws {
        let root = try fixture("claude"); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(".claude"), destination = root.appendingPathComponent(".claude-team")
        let staging = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("projects/-work-repo"), withIntermediateDirectories: true)
        try Data("instructions".utf8).write(to: source.appendingPathComponent("CLAUDE.md"))
        try Data(#"{"model":"sonnet","hooks":{"Stop":[]},"env":{"ANTHROPIC_API_KEY":"fixture-secret"}}"#.utf8).write(to: source.appendingPathComponent("settings.json"))
        let metadata = #"{"installPath":"\#(source.path)/plugins/cache/item","description":"keep \#(source.path)/ in prose","otherPath":"\#(source.path)-other/file"}"#
        try Data(metadata.utf8).write(to: source.appendingPathComponent("plugins/config.json"))
        try Data("conversation".utf8).write(to: source.appendingPathComponent("projects/-work-repo/session.jsonl"))
        try Data("credential".utf8).write(to: source.appendingPathComponent("auth.json"))
        let pair = SetupAgentPair(kind: .claude, choice: .create, sourcePath: source.path, destinationPath: destination.path,
                                  categories: [.preferences, .instructions, .plugins, .history], projectPaths: [source.appendingPathComponent("projects/-work-repo").path])
        let adapter = ClaudeConfigurationMigration()
        #expect(try adapter.availableProjects(sourcePath: source.path) == [Paths.canonical(source.appendingPathComponent("projects/-work-repo").path)])
        let preview = try adapter.preview(pair: pair)
        #expect(preview.entries.contains { $0.destinationRelativePath == "CLAUDE.md" })
        #expect(preview.entries.contains { $0.destinationRelativePath == "projects/-work-repo/session.jsonl" })
        #expect(!preview.entries.contains { $0.sourceRelativePath == "auth.json" })
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try adapter.write(preview: preview, pair: pair, staging: staging)
        let settings = try String(contentsOf: staging.appendingPathComponent("settings.json"), encoding: .utf8)
        #expect(settings.contains("sonnet") && !settings.contains("fixture-secret") && !settings.contains("hooks"))
        let copiedMetadata = try String(contentsOf: staging.appendingPathComponent("plugins/config.json"), encoding: .utf8)
        #expect(copiedMetadata.contains(destination.path + "/plugins/cache/item"))
        #expect(copiedMetadata.contains("keep \(source.path)/ in prose"))
        #expect(copiedMetadata.contains(source.path + "-other/file"))
        #expect(try Data(contentsOf: source.appendingPathComponent("plugins/config.json")) == Data(metadata.utf8))
    }

    @Test func changedSourceOrSelectionInvalidatesPreview() throws {
        let root = try fixture("changed"); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("model = \"gpt-5\"".utf8).write(to: source.appendingPathComponent("config.toml"))
        let pair = SetupAgentPair(kind: .codex, choice: .create, sourcePath: source.path,
                                  destinationPath: root.appendingPathComponent(".codex-team").path, categories: [.preferences])
        let adapter = CodexConfigurationMigration()
        let preview = try adapter.preview(pair: pair)
        try Data("model = \"gpt-5.1\"".utf8).write(to: source.appendingPathComponent("config.toml"))
        #expect(throws: ConfigurationMigrationError.self) { try adapter.write(preview: preview, pair: pair, staging: stage) }
        var changedSelection = pair; changedSelection.categories = [.connections]
        #expect(throws: ConfigurationMigrationError.self) { try adapter.write(preview: preview, pair: changedSelection, staging: stage) }
    }

    @Test func malformedDocumentsAndExternalLinksAreReportedAndSkipped() throws {
        let root = try fixture("unsafe"); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), external = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try Data("[broken".utf8).write(to: source.appendingPathComponent("config.toml"))
        try Data("external".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("skills/shared"), withDestinationURL: external)
        let pair = SetupAgentPair(kind: .codex, choice: .create, sourcePath: source.path,
                                  destinationPath: root.appendingPathComponent("destination").path, categories: [.preferences, .reusable])
        let preview = try CodexConfigurationMigration().preview(pair: pair)
        #expect(preview.entries.isEmpty)
        #expect(preview.warnings.contains { $0.contains("config.toml") && $0.contains("parsed safely") })
        #expect(preview.warnings.contains { $0.contains("outside the source") })
    }
}
