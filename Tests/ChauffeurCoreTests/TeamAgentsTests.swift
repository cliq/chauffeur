import Foundation
import Testing
@testable import ChauffeurCore

struct TeamAgentsTests {
    private func temporaryRoot() -> URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("team-agents-\(UUID())").resolvingSymlinksInPath() }

    @Test func presetDirectorySurvivesTeamResolutionAndCustomCopyPersistence() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        var team = PresetSet(name: "Work", agentSelection: .allBase)
        team.configurationDirectories = ["claude": "/team/claude"]
        let savedTeam = try await store.save(team)
        // Decode the new field to exercise backward-compatible persistence too.
        let base = BaseAgentPreset(name: "Claude Code Local", kind: .claude, executable: "claude")
        var object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encode(base)) as? [String: Any])
        object["configurationDirectoryOverride"] = "/local/claude-local"
        let local = try JSONCoding.decode(BaseAgentPreset.self, from: JSONSerialization.data(withJSONObject: object))
        try await store.save(local)
        var snapshot = await store.reload()
        #expect(snapshot.agents(in: team).first?.configurationDirectory == "/local/claude-local")
        team.agentSelection = .custom
        let custom = try await store.save(team, expectedVersion: savedTeam.version)
        snapshot = await store.reload()
        var copy = try #require(snapshot.agents(in: custom.value).first)
        copy.name = "Renamed local"
        let stored = try #require(snapshot.presets.first { $0.value.id == copy.id })
        try await store.save(copy, expectedVersion: stored.version)
        snapshot = await store.reload()
        #expect(snapshot.agents(in: custom.value).first?.configurationDirectory == "/local/claude-local")
    }

    @Test func resolvedAgentDirectoryWinsOverTeamEnvironment() throws {
        let agent = AgentPreset(setID: UUID(), name: "Local", kind: .claude, executable: "claude", configurationDirectory: "/local/claude-local")
        let environment = try LaunchPolicy.environment(base: [:], preset: agent, projectID: UUID(), sessionID: UUID(), token: "test", configurationEnvironment: ["CLAUDE_CONFIG_DIR": "/team/claude", "CODEX_HOME": "/team/codex"], allowMissingConfiguration: true)
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/local/claude-local")
        #expect(environment["CODEX_HOME"] == "/team/codex")
    }

    @Test func inheritedCatalogUsesEachTeamsDirectoriesAndCustomCopiesStayIndependent() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        var work = PresetSet(name: "Work", agentSelection: .allBase)
        work.configurationDirectories = ["claude": "/work/claude", "codex": "/work/codex"]
        var personal = PresetSet(name: "Personal", agentSelection: .allBase)
        personal.configurationDirectories = ["claude": "/personal/claude"]
        let savedWork = try await store.save(work)
        try await store.save(personal)
        var opus = BaseAgentPreset(name: "Opus", kind: .claude, executable: "claude")
        opus.arguments = ["--model", "opus"]
        let savedBase = try await store.save(opus)
        var project = Project(name: "Work project", presetSetID: work.id); project.lastPresetID = opus.id
        try await store.save(project)
        var snapshot = await store.reload()
        #expect(snapshot.agents(in: work).first?.configurationDirectory == "/work/claude")
        #expect(snapshot.agents(in: personal).first?.configurationDirectory == "/personal/claude")
        work.agentSelection = .custom
        let custom = try await store.save(work, expectedVersion: savedWork.version)
        snapshot = await store.reload()
        let copy = try #require(snapshot.agents(in: custom.value).first)
        #expect(copy.id != opus.id)
        #expect(snapshot.projects.first?.value.lastPresetID == copy.id)
        #expect(snapshot.agents(in: custom.value).allSatisfy { $0.id != opus.id })
        opus.arguments = ["--model", "sonnet"]
        let changed = try await store.save(opus, expectedVersion: savedBase.version)
        #expect(changed.value.revision == savedBase.value.revision + 1)
        snapshot = await store.reload()
        #expect(snapshot.agents(in: personal).first?.arguments == ["--model", "sonnet"])
        #expect(snapshot.agents(in: custom.value).first?.arguments == ["--model", "opus"])
        opus = changed.value; opus.archived = true
        try await store.save(opus, expectedVersion: changed.version)
        snapshot = await store.reload()
        #expect(snapshot.agents(in: personal).isEmpty)
        #expect(snapshot.agents(in: custom.value).count == 1)
        #expect(snapshot.agents(teamID: personal.id).allSatisfy { $0.id != copy.id })
    }

    @Test func migrationPreservesIDsAndPicksFirstActiveDirectoryAndIsIdempotent() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let team = PresetSet(name: "Legacy")
        try await store.save(team)
        let zeta = AgentPreset(setID: team.id, name: "Zeta", kind: .codex, executable: "codex", configurationDirectory: "/old/zeta")
        let alpha = AgentPreset(setID: team.id, name: "Alpha", kind: .codex, executable: "codex", configurationDirectory: "/old/alpha")
        var archived = AgentPreset(setID: team.id, name: "AAA", kind: .codex, executable: "codex", configurationDirectory: "/old/archived")
        archived.archived = true
        try await store.save(zeta); try await store.save(alpha); try await store.save(archived)
        var project = Project(name: "Project", presetSetID: team.id); project.lastPresetID = zeta.id
        try await store.save(project)
        try await store.migrateTeamAgents()
        let first = await store.reload()
        let migrated = try #require(first.presetSets.first?.value)
        #expect(migrated.id == team.id && migrated.agentSelection == .custom)
        #expect(migrated.configurationDirectories?["codex"] == "/old/alpha")
        #expect(Set(first.agents(in: migrated).map(\.id)) == [alpha.id, zeta.id])
        #expect(first.agents(in: migrated).allSatisfy { $0.configurationDirectory == "/old/alpha" })
        #expect(first.projects.first?.value.lastPresetID == zeta.id)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("migrations/team-agents-v2/preset-sets/legacy/preset-set.json").path))
        try await store.migrateTeamAgents()
        let again = await store.reload()
        #expect(again.presetSets.first?.version == first.presetSets.first?.version)
        #expect(Set(again.baseAgentPresets.map(\.value.id)) == Set(first.baseAgentPresets.map(\.value.id)))
        #expect(again.errors.isEmpty)
    }

    @Test func baseFileEditsRefreshInheritedAgentsWithoutRewritingTeams() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let team = try await store.save(PresetSet(name: "Live", agentSelection: .allBase))
        let base = try await store.save(BaseAgentPreset(name: "Codex", kind: .codex, executable: "codex"))
        _ = await store.refresh()
        var changed = base.value; changed.arguments = ["--yolo"]; changed.revision += 1
        try JSONCoding.encode(changed).write(to: URL(fileURLWithPath: base.path), options: .atomic)
        var snapshot = await store.refresh()
        for _ in 0..<100 where snapshot.agents(in: team.value).first?.arguments != ["--yolo"] {
            try await Task.sleep(for: .milliseconds(20))
            snapshot = await store.refresh()
        }
        #expect(snapshot.agents(in: team.value).first?.arguments == ["--yolo"])
        #expect(snapshot.presetSets.first?.version == team.version)
    }

    @Test func legacyTeamDefaultIsIgnoredWhenReadingAndNotWrittenBack() throws {
        let team = PresetSet(name: "Legacy")
        var object = try #require(JSONSerialization.jsonObject(with: JSONCoding.encode(team)) as? [String: Any])
        object["defaultPresetID"] = UUID().uuidString
        let decoded = try JSONCoding.decode(PresetSet.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == team)
        let saved = try #require(JSONSerialization.jsonObject(with: JSONCoding.encode(decoded)) as? [String: Any])
        #expect(saved["defaultPresetID"] == nil)
    }

    @Test func oldSnapshotsDecodeWithoutAGlobalCatalog() throws {
        let encoded = try JSONCoding.encode(StoreSnapshot())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "baseAgentPresets")
        let decoded = try JSONCoding.decode(StoreSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.baseAgentPresets.isEmpty)
    }

    @Test func shellsReceiveBothDirectoriesWithAnEmptyCustomListAndMissingPaths() throws {
        var team = PresetSet(name: "Empty", agentSelection: .custom)
        team.configurationDirectories = ["codex": "/missing/codex"]
        let snapshot = StoreSnapshot()
        let environment = snapshot.configurationEnvironment(in: team)
        #expect(environment["CODEX_HOME"] == "/missing/codex")
        #expect(environment["CLAUDE_CONFIG_DIR"] == team.configurationDirectory(for: .claude))
        #expect(snapshot.agents(in: team).isEmpty)
        let shell = AgentPreset(setID: team.id, name: "Shell", kind: .shell, executable: "/bin/zsh", configurationDirectory: "/tmp")
        let result = try LaunchPolicy.environment(base: ["CODEX_HOME": "/wrong", "OPENAI_API_KEY": "secret"], preset: shell, projectID: UUID(), sessionID: UUID(), token: "", configurationEnvironment: environment)
        #expect(result["CODEX_HOME"] == "/missing/codex")
        #expect(result["CLAUDE_CONFIG_DIR"] == environment["CLAUDE_CONFIG_DIR"])
        #expect(result["OPENAI_API_KEY"] == nil && result["CHAUFFEUR_SESSION_TOKEN"] == nil)
    }

    @Test func changingModesRestoresExistingCustomCopiesAndRejectsStaleEdits() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let base = BaseAgentPreset(name: "Codex", kind: .codex, executable: "codex")
        try await store.save(base)
        var saved = try await store.save(PresetSet(name: "Team", agentSelection: .allBase))
        var team = saved.value; team.agentSelection = .custom
        saved = try await store.save(team, expectedVersion: saved.version)
        let copyIDs = await store.reload().agents(in: saved.value).map(\.id)
        team = saved.value; team.agentSelection = .allBase
        saved = try await store.save(team, expectedVersion: saved.version)
        try await store.save(BaseAgentPreset(name: "Claude", kind: .claude, executable: "claude"))
        team = saved.value; team.agentSelection = .custom
        saved = try await store.save(team, expectedVersion: saved.version)
        #expect(await store.reload().agents(in: saved.value).map(\.id) == copyIDs)
        await #expect(throws: ChauffeurError.self) { try await store.save(team, expectedVersion: "stale") }
    }
}
