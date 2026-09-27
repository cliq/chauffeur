import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct KimiSetupTests {
    @Test func loginAndCredentialInspectionUseTheSelectedHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = root.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        let context = AuthenticationContext(kind: .kimi, executable: "/bin/false", configurationPath: root.path,
                                            baseEnvironment: ["KIMI_CODE_HOME": "/other", "KIMI_MODEL_NAME": "other", "CHAUFFEUR_SESSION_TOKEN": "must-not-leak"], workingDirectory: root.path)
        let adapter = KimiAuthentication()
        let login = try await adapter.loginCommand(context: context)
        #expect(login.arguments == ["login"])
        #expect(login.environment["KIMI_CODE_HOME"] == Paths.canonical(root.path))
        #expect(login.environment["CHAUFFEUR_SESSION_TOKEN"] == nil && login.environment["KIMI_MODEL_NAME"] == nil)
        #expect(await adapter.status(context: context).phase == .unableToVerify)
        try Data(#"{"access_token":"fixture-secret","refresh_token":"fixture-refresh"}"#.utf8).write(to: credentials.appendingPathComponent("kimi-code.json"))
        let status = await adapter.status(context: context)
        #expect(status.phase == .connected)
        #expect(status.message?.contains("fixture-secret") == false)
    }

    @Test func newHomeCopiesPortableFilesAndLeavesCredentialsBehind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills/example"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("Instructions".utf8).write(to: source.appendingPathComponent("AGENTS.md"))
        try Data("Skill".utf8).write(to: source.appendingPathComponent("skills/example/SKILL.md"))
        try Data("api_key = 'fixture-secret'".utf8).write(to: source.appendingPathComponent("config.toml"))
        let pair = SetupAgentPair(kind: .kimi, executable: "kimi", choice: .create, sourcePath: source.path,
                                  destinationPath: root.appendingPathComponent("destination").path, categories: [.instructions, .reusable])
        let adapter = KimiConfigurationMigration()
        let preview = try adapter.preview(pair: pair)
        #expect(Set(preview.entries.map(\.destinationRelativePath)) == ["AGENTS.md", "skills/example/SKILL.md"])
        try adapter.write(preview: preview, pair: pair, staging: staging)
        #expect(try String(contentsOf: staging.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "Instructions")
        #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("config.toml").path))
    }
}
