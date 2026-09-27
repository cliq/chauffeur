import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct PiSetupTests {
    @Test func loginOpensInteractivePiAndCredentialInspectionUsesTheSelectedHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-pi-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = AuthenticationContext(
            kind: .pi,
            executable: "/bin/false",
            configurationPath: root.path,
            baseEnvironment: [
                "PI_CODING_AGENT_DIR": "/other",
                "OPENAI_API_KEY": "must-not-leak",
                "CHAUFFEUR_SESSION_TOKEN": "must-not-leak"
            ],
            workingDirectory: root.path
        )
        let adapter = PiAuthentication()

        let login = try await adapter.loginCommand(context: context)

        #expect(login.arguments.isEmpty)
        #expect(login.environment["PI_CODING_AGENT_DIR"] == Paths.canonical(root.path))
        #expect(login.environment["OPENAI_API_KEY"] == nil)
        #expect(login.environment["CHAUFFEUR_SESSION_TOKEN"] == nil)
        #expect(await adapter.status(context: context).phase == .signInRequired)

        let secret = "fixture-secret-that-must-not-appear"
        try Data(#"{"openai":{"type":"api_key","key":"fixture-secret-that-must-not-appear"}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        let status = await adapter.status(context: context)
        #expect(status.phase == .connected)
        #expect(status.method == "Pi credentials")
        #expect(!String(decoding: try JSONCoding.encode(status), as: UTF8.self).contains(secret))
    }

    @Test func malformedFileIsUnavailableAndValidEmptyRecordsRequireSignIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-pi-invalid-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = AuthenticationContext(kind: .pi, executable: "/bin/false", configurationPath: root.path,
                                            baseEnvironment: [:], workingDirectory: root.path)
        let adapter = PiAuthentication()
        let auth = root.appendingPathComponent("auth.json")

        try Data("not json".utf8).write(to: auth)
        #expect(await adapter.status(context: context).phase == .unableToVerify)

        try Data(#"{"openai":{"type":"api_key","env":{}},"anthropic":{"type":"oauth","access":"","refresh":"","expires":0}}"#.utf8).write(to: auth)
        #expect(await adapter.status(context: context).phase == .signInRequired)
    }

    @Test func malformedCredentialOrSiblingInvalidatesTheEntireCredentialFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-pi-malformed-record-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = AuthenticationContext(kind: .pi, executable: "/bin/false", configurationPath: root.path,
                                            baseEnvironment: [:], workingDirectory: root.path)
        let auth = root.appendingPathComponent("auth.json")
        let malformed = [
            #"{"valid":{"type":"api_key","key":"fixture"},"invalid":{"type":"api_key","key":42,"env":{"PROFILE":"work"}}}"#,
            #"{"valid":{"type":"api_key","key":"fixture"},"invalid":{"type":"api_key","env":{"PROFILE":42}}}"#,
            #"{"valid":{"type":"api_key","key":"fixture"},"invalid":{"type":"oauth","access":"access","expires":1}}"#,
            #"{"valid":{"type":"api_key","key":"fixture"},"invalid":{"type":"oauth","access":"access","refresh":"refresh","expires":"later"}}"#,
            #"{"valid":{"type":"api_key","key":"fixture"},"invalid":"credential"}"#
        ]

        for document in malformed {
            try Data(document.utf8).write(to: auth)
            #expect(await PiAuthentication().status(context: context).phase == .unableToVerify)
        }
    }

    @Test func providerScopedEnvironmentCredentialIsRecognizedWithoutResolvingItsValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-pi-env-auth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"amazon-bedrock":{"type":"api_key","env":{"AWS_PROFILE":"$PI_TEST_PROFILE"}}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        let context = AuthenticationContext(kind: .pi, executable: "/bin/false", configurationPath: root.path,
                                            baseEnvironment: ["PI_TEST_PROFILE": "fixture-sensitive"], workingDirectory: root.path)

        let status = await PiAuthentication().status(context: context)

        #expect(status.phase == .connected)
        #expect(!String(decoding: try JSONCoding.encode(status), as: UTF8.self).contains("fixture-sensitive"))

        try Data(#"{"openai-codex":{"type":"oauth","access":"access-fixture","refresh":"refresh-fixture","expires":1}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))
        #expect(await PiAuthentication().status(context: context).phase == .connected)
    }

    @Test func newHomeCopiesPortableResourcesAndLeavesExecutableConfigurationBehind() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-pi-copy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), staging = root.appendingPathComponent("staging")
        for directory in ["skills/example", "prompts", "themes", "extensions", "commands", "sessions"] {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let files: [String: String] = [
            "AGENTS.md": "Instructions",
            "AGENTS.override.md": "Override instructions",
            "AGENTS.MD": "Uppercase extension instructions",
            "CLAUDE.md": "Claude-compatible instructions",
            "CLAUDE.MD": "Uppercase Claude-compatible instructions",
            "SYSTEM.md": "System instructions",
            "APPEND_SYSTEM.md": "Additional system instructions",
            "skills/example/SKILL.md": "Skill",
            "prompts/review.md": "Review prompt",
            "themes/work.json": "{}",
            "auth.json": #"{"openai":{"type":"api_key","key":"fixture-secret"}}"#,
            "models.json": #"{"providers":[]}"#,
            "settings.json": #"{"extensions":["./extensions/run.ts"]}"#,
            "extensions/run.ts": "throw new Error('must not copy')",
            "commands/run.md": "Run something",
            "sessions/history.jsonl": "secret history"
        ]
        for (path, contents) in files {
            try Data(contents.utf8).write(to: source.appendingPathComponent(path))
        }
        let pair = SetupAgentPair(kind: .pi, executable: "pi", choice: .create, sourcePath: source.path,
                                  destinationPath: root.appendingPathComponent("destination").path,
                                  categories: [.preferences, .instructions, .reusable])

        let adapter = PiConfigurationMigration()
        let preview = try adapter.preview(pair: pair)

        let supportedInstructionNames: Set<String> = [
            "AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD", "SYSTEM.md", "APPEND_SYSTEM.md"
        ]
        let actualSourceNames = try Set(FileManager.default.contentsOfDirectory(atPath: source.path))
        var expected: [String: CopyCategory] = [
            "skills/example/SKILL.md": .reusable,
            "prompts/review.md": .reusable,
            "themes/work.json": .preferences
        ]
        for name in supportedInstructionNames.intersection(actualSourceNames) { expected[name] = .instructions }
        #expect(Dictionary(uniqueKeysWithValues: preview.entries.map { ($0.destinationRelativePath, $0.category) }) == expected)
        #expect(preview.entries.map(\.destinationRelativePath).count == Set(preview.entries.map(\.destinationRelativePath)).count)
        try adapter.write(preview: preview, pair: pair, staging: staging)
        for name in supportedInstructionNames.intersection(actualSourceNames) {
            #expect(try Data(contentsOf: staging.appendingPathComponent(name)) == Data(contentsOf: source.appendingPathComponent(name)))
        }
        for excluded in ["auth.json", "models.json", "settings.json", "extensions/run.ts", "commands/run.md", "sessions/history.jsonl"] {
            #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent(excluded).path))
        }
    }
}
