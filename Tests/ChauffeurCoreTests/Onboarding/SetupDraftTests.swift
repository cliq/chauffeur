import Foundation
import Testing
@testable import ChauffeurCore

struct SetupDraftTests {
    @Test func draftRoundTripKeepsStableTeamAndPairIDs() throws {
        let pair = SetupAgentPair(kind: .claude, executable: "/usr/bin/true", destinationPath: "/tmp/.claude-work")
        var draft = SetupDraft()
        draft.executables = [CLIKind.claude.rawValue: "/opt/tools/claude custom"]
        draft.teams = [SetupTeam(name: "Work", agents: [pair])]
        draft.defaultTeamID = draft.teams[0].id

        let restored = try JSONCoding.decode(SetupDraft.self, from: JSONCoding.encode(draft))

        #expect(restored.teams.map(\.id) == draft.teams.map(\.id))
        #expect(restored.teams[0].agents.map(\.id) == [pair.id])
        #expect(restored.executables == draft.executables)
        #expect(restored.completed == false)
        #expect(restored.teams[0].agents[0].auth.phase == .notChecked)
    }

    @Test func olderDraftWithoutExecutableSelectionsDefaultsToEmpty() throws {
        let data = try JSONCoding.encode(SetupDraft())
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "executables")
        let restored = try JSONCoding.decode(SetupDraft.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.executables.isEmpty)
    }

    @Test func futureSchemasAndDuplicatePairIDsAreRejectedOnDecode() throws {
        let pairID = UUID()
        let pair = SetupAgentPair(id: pairID, kind: .codex, destinationPath: "/tmp/.codex-one")
        let duplicate = SetupAgentPair(id: pairID, kind: .claude, destinationPath: "/tmp/.claude-one")
        let invalid = SetupDraft(teams: [
            SetupTeam(name: "One", agents: [pair]),
            SetupTeam(name: "Two", agents: [duplicate])
        ])
        #expect(throws: ChauffeurError.self) {
            try JSONCoding.decode(SetupDraft.self, from: JSONCoding.encode(invalid))
        }

        let future = SetupDraft(schemaVersion: SetupDraft.currentSchemaVersion + 1)
        #expect(throws: ChauffeurError.self) {
            try JSONCoding.decode(SetupDraft.self, from: JSONCoding.encode(future))
        }
    }

    @Test func draftAllowsPartiallyTypedPathsButRejectsNonAgentsAndMissingDefault() throws {
        let partial = SetupAgentPair(kind: .codex, sourcePath: "~/.", destinationPath: "/tmp/unfinished ")
        try SetupDraft(teams: [SetupTeam(name: "", agents: [partial])]).validate()
        let shell = SetupAgentPair(kind: .shell, sourcePath: "relative", destinationPath: "other")
        let invalid = SetupDraft(teams: [SetupTeam(name: "Work", agents: [shell])], defaultTeamID: UUID())
        #expect(throws: ChauffeurError.self) { try invalid.validate() }
    }
}
