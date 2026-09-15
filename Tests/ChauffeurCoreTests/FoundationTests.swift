import Foundation
import Testing
@testable import ChauffeurCore

struct FoundationTests {
    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func canonicalDuplicateAndDiscovery() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("répo space")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/hidden/.git"), withIntermediateDirectories: true)
        let worktree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /somewhere".utf8).write(to: worktree.appendingPathComponent(".git"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: repo)
        var project = Project(name: "A", presetSetID: UUID())
        project.addFolder(ProjectFolder(path: repo.path))
        project.addFolder(ProjectFolder(path: root.appendingPathComponent("alias").path))
        #expect(project.folders.count == 1)
        let discovered = RepositoryDiscovery.scan(parent: root.path)
        #expect(discovered.folders.count == 2)
        #expect(discovered.errors.isEmpty)
        #expect(RepositoryDiscovery.scan(parent: root.path, isCancelled: { true }).cancelled)
    }
    @Test func filteringIsPerChildAndMissingConfigFails() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let preset = AgentPreset(setID: UUID(), name: "A", kind: .codex, executable: "/bin/cat", configurationDirectory: root.path)
        let inherited = ["CODEX_HOME": "/bad", "CLAUDE_CONFIG_DIR": "/bad", "OPENAI_API_KEY": "secret", "ANTHROPIC_AUTH_TOKEN": "secret", "CLAUDE_CODE_OAUTH_TOKEN": "secret", "AWS_PROFILE": "bad", "PATH": "/bin", "HOME": "/real-home", "CHAUFFEUR_SESSION_TOKEN": "parent"]
        let first = try LaunchPolicy.environment(base: inherited, preset: preset, sessionID: UUID(), token: "first")
        let second = try LaunchPolicy.environment(base: inherited, preset: preset, sessionID: UUID(), token: "second")
        #expect(first["CODEX_HOME"] == Paths.canonical(root.path))
        #expect(first["HOME"] == "/real-home")
        #expect(first["OPENAI_API_KEY"] == nil && first["CLAUDE_CONFIG_DIR"] == nil && first["AWS_PROFILE"] == nil)
        #expect(first["CHAUFFEUR_SESSION_TOKEN"] != second["CHAUFFEUR_SESSION_TOKEN"])
        #expect(inherited["CODEX_HOME"] == "/bad")
        var invalid = preset; invalid.configurationDirectory += "/missing"
        #expect(throws: ChauffeurError.self) { try LaunchPolicy.environment(base: inherited, preset: invalid, sessionID: UUID(), token: "x") }
    }
    @Test func managedArgumentsCannotBeOverridden() throws {
        for args in [["--cd=/tmp"], ["-C/tmp"], ["-c", "mcp_servers.chauffeur.url='bad'"], ["resume", "--last"], ["--worktree"]] {
            #expect(throws: ChauffeurError.self) { try LaunchPolicy.validateArguments(args, kind: .codex) }
        }
        for args in [["--settings", "bad.json"], ["--strict-mcp-config"], ["-r123"], ["--session-id=x"], ["--mcp-config=x"]] {
            #expect(throws: ChauffeurError.self) { try LaunchPolicy.validateArguments(args, kind: .claude) }
        }
        try LaunchPolicy.validateArguments(["--model", "chosen-model", "--sandbox=workspace-write", "--search"], kind: .codex)
        try LaunchPolicy.validateArguments(["--model", "chosen-model", "--permission-mode", "default"], kind: .claude)
    }
    @Test func fileStoreExternalEditsCorruptionAndSlugs() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let first = try await store.save(PresetSet(name: "Client / One"))
        let second = try await store.save(PresetSet(name: "Client / One"))
        #expect(first.path != second.path)
        #expect(second.path.contains("client-one-2"))
        var changed = first.value; changed.name = "Renamed"
        try JSONCoding.encode(changed).write(to: URL(fileURLWithPath: first.path))
        await #expect(throws: ChauffeurError.self) { try await store.save(first.value, expectedVersion: first.version) }
        let reloaded = await store.reload()
        #expect(reloaded.presetSets.contains { $0.value.name == "Renamed" })
        let renamed = try #require(reloaded.presetSets.first { $0.value.id == first.value.id })
        let saved = try await store.save(changed, expectedVersion: renamed.version)
        #expect(saved.path == first.path)
        try Data("{ corrupt token=secret".utf8).write(to: URL(fileURLWithPath: second.path))
        let corrupted = await store.reload()
        #expect(corrupted.presetSets.count == 1)
        #expect(corrupted.errors.first?.path == second.path)
        #expect(!corrupted.errors.contains { $0.message.contains("secret") })
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
    @Test func groupAndLifecycleValidation() throws {
        var project = Project(name: "Project", presetSetID: UUID())
        try project.validate()
        project.groups[0].archived = true
        #expect(throws: ChauffeurError.self) { try project.validate() }
        #expect(SessionState.turnFinished.isLive)
        #expect(!SessionState.interrupted.isLive)
        #expect(!SessionState.failed.isLive)
    }
    @Test func executableSymlinksAndMCPArgumentTypes() throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("linked-cli")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/cat"))
        #expect(try Paths.executable(link.path, environment: [:]) == Paths.canonical("/bin/cat"))
        #expect(throws: ChauffeurError.self) { try MCPTools.validate(name: "chauffeur_inbox", arguments: .object(["waitSeconds": .number(0.5)])) }
        #expect(throws: ChauffeurError.self) { try MCPTools.validate(name: "chauffeur_discover", arguments: .object(["groupID": .string(UUID().uuidString)])) }
        #expect(throws: ChauffeurError.self) { try MCPTools.validate(name: "chauffeur_send_message", arguments: .object(["recipientID": .string("peer"), "body": .string("message"), "retryKey": .string("retry"), "references": .array([.number(2)])])) }
        try MCPTools.validate(name: "chauffeur_inbox", arguments: .object(["waitSeconds": .number(25)]))
    }
}
