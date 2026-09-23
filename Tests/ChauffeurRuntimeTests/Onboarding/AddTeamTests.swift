import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct AddTeamTests {
    private struct Fixture {
        let root: URL
        let store: FileStore
        let coordinator: OnboardingCoordinator
        let existing: Stored<PresetSet>
        let draft: Stored<SetupDraft>
        let source: URL

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("add-team-\(UUID())")
            source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("model = \"test\"\n".utf8).write(to: source.appendingPathComponent("config.toml"))
            try Data("secret".utf8).write(to: source.appendingPathComponent("auth.json"))
            store = try FileStore(root: root.appendingPathComponent("store"))
            var team = PresetSet(name: "Existing", agentSelection: .allBase)
            team.isDefault = true
            existing = try await store.save(team)
            draft = try await store.saveSetupDraft(SetupDraft(teams: [SetupTeam(name: "Unfinished")]))
            coordinator = try OnboardingCoordinator(store: store, root: root, environment: ["HOME": root.path], home: root)
        }

        func pair(_ name: String = "new-config", kind: CLIKind = .codex) -> SetupAgentPair {
            SetupAgentPair(kind: kind, executable: kind.rawValue, choice: .create,
                sourcePath: source.path, destinationPath: root.appendingPathComponent(name).path)
        }

        func preview(_ pair: SetupAgentPair) async throws -> CopyPreview {
            try await coordinator.handle(IPCRequest("previewTeamConfiguration", params: .object(["pair": try .from(pair)])))
                .decode(CopyPreview.self)
        }

        func add(_ team: PresetSet, pairs: [SetupAgentPair]) async throws -> Stored<PresetSet> {
            try await coordinator.handle(IPCRequest("addTeam", params: .object([
                "record": try .from(team), "configurations": try .from(pairs)
            ]))).decode(Stored<PresetSet>.self)
        }

        func assertExistingStateUnchanged() async throws {
            let snapshot = await store.reload()
            #expect(snapshot.presetSets.first { $0.value.id == existing.value.id }?.version == existing.version)
            #expect(try await store.setupDraft()?.version == draft.version)
        }
    }

    @Test func previewThenAbandonLeavesTeamsDraftAndFilesystemUntouched() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let pair = f.pair()
        let preview = try await f.preview(pair)
        #expect(preview.entries.contains { $0.destinationRelativePath == "config.toml" })
        #expect(!preview.entries.contains { $0.destinationRelativePath == "auth.json" })
        #expect(!FileManager.default.fileExists(atPath: pair.destinationPath))
        #expect(try await f.store.setupOperations().isEmpty)
        #expect(await f.store.reload().presetSets.count == 1)
        try await f.assertExistingStateUnchanged()
    }

    @Test func addsTeamUsingReviewedMigrationWithoutChangingOnboarding() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var pair = f.pair()
        pair.previewID = try await f.preview(pair).id
        var team = PresetSet(name: "Client", agentSelection: .allBase)
        team.configurationDirectories = ["codex": pair.destinationPath]
        let saved = try await f.add(team, pairs: [pair])
        #expect(saved.value.id == team.id)
        #expect(FileManager.default.fileExists(atPath: pair.destinationPath + "/config.toml"))
        #expect(!FileManager.default.fileExists(atPath: pair.destinationPath + "/auth.json"))
        #expect(try String(contentsOf: f.source.appendingPathComponent("auth.json"), encoding: .utf8) == "secret")
        #expect(await f.store.reload().presetSets.count == 2)
        try await f.assertExistingStateUnchanged()
    }

    @Test func invalidSecondPreviewDoesNotPublishFirstFolder() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var first = f.pair()
        first.previewID = try await f.preview(first).id
        let second = f.pair("claude-new", kind: .claude)
        var team = PresetSet(name: "Client", agentSelection: .allBase)
        team.configurationDirectories = ["codex": first.destinationPath, "claude": second.destinationPath]
        await #expect(throws: (any Error).self) { try await f.add(team, pairs: [first, second]) }
        #expect(!FileManager.default.fileExists(atPath: first.destinationPath))
        #expect(await f.store.reload().presetSets.count == 1)
        try await f.assertExistingStateUnchanged()
    }

    @Test func changedSelectionRequiresNewPreview() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var pair = f.pair()
        pair.previewID = try await f.preview(pair).id
        pair.categories = []
        var team = PresetSet(name: "Client", agentSelection: .allBase)
        team.configurationDirectories = ["codex": pair.destinationPath]
        await #expect(throws: (any Error).self) { try await f.add(team, pairs: [pair]) }
        #expect(!FileManager.default.fileExists(atPath: pair.destinationPath))
        try await f.assertExistingStateUnchanged()
    }

    @Test func retryAfterPartialPublicationPreservesCreatedFolder() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var first = f.pair()
        first.previewID = try await f.preview(first).id
        var second = f.pair("missing-parent/claude-new", kind: .claude)
        second.sourcePath = nil
        second.previewID = try await f.preview(second).id
        var team = PresetSet(name: "Client", agentSelection: .allBase)
        team.configurationDirectories = ["codex": first.destinationPath, "claude": second.destinationPath]
        await #expect(throws: (any Error).self) { try await f.add(team, pairs: [first, second]) }
        #expect(FileManager.default.fileExists(atPath: first.destinationPath + "/config.toml"))
        #expect(await f.store.reload().presetSets.count == 1)
        let marker = URL(fileURLWithPath: first.destinationPath).appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("missing-parent"), withIntermediateDirectories: true)
        let saved = try await f.add(team, pairs: [first, second])
        #expect(saved.value.id == team.id)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
        try await f.assertExistingStateUnchanged()
    }

    @Test func addTeamHonorsDefaultSelectionThroughRuntime() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let runtime = try RuntimeCoordinator(root: f.root.appendingPathComponent("store"), ctlPath: "/bin/false",
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": f.root.path])
        var team = PresetSet(name: "New default", agentSelection: .allBase)
        team.isDefault = true
        let saved = try await runtime.handle(IPCRequest("addTeam", params: .object([
            "record": try .from(team), "configurations": .array([])
        ]))).decode(Stored<PresetSet>.self)
        #expect(saved.value.isDefault)
        let sets = await runtime.store.refresh().presetSets
        #expect(sets.count == 2)
        #expect(sets.filter { $0.value.isDefault }.map { $0.value.id } == [team.id])
        #expect(try await f.store.setupDraft()?.version == f.draft.version)
    }

    @Test func addsTeamWithExistingFoldersAndRejectsOverwrite() async throws {
        let f = try await Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var team = PresetSet(name: "Client", agentSelection: .custom)
        team.configurationDirectories = ["codex": f.source.path]
        let saved = try await f.add(team, pairs: [])
        #expect(saved.value.agentSelection == .custom)
        team.id = f.existing.value.id
        await #expect(throws: (any Error).self) { try await f.add(team, pairs: []) }
        try await f.assertExistingStateUnchanged()
    }
}
