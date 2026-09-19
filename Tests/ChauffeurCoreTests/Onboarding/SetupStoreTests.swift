import Foundation
import Testing
@testable import ChauffeurCore

struct SetupStoreTests {
    @Test func draftIsSingleVersionedRecordAndRejectsStaleWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-setup-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        var draft = SetupDraft(teams: [SetupTeam(name: "Work")])

        let first = try await store.saveSetupDraft(draft)
        #expect(try await store.setupDraft()?.value.id == draft.id)

        draft.step = .teams
        let second = try await store.saveSetupDraft(draft, expectedVersion: first.version)
        var stale = first.value
        stale.dismissed = true
        await #expect(throws: ChauffeurError.self) {
            try await store.saveSetupDraft(stale, expectedVersion: first.version)
        }
        #expect(try await store.setupDraft()?.version == second.version)
        await #expect(throws: ChauffeurError.self) { try await store.saveSetupDraft(SetupDraft()) }
    }

    @Test func operationJournalKeepsStablePresetIDsAndVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-setup-operations-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("onboarding/operations"))
        #expect(try await store.setupOperations().isEmpty)
        let baseID = UUID(), customID = UUID()
        var operation = SetupOperation(
            draftID: UUID(), pairID: UUID(), destinationPath: "/tmp/.codex-work",
            presetIDs: [baseID.uuidString: customID]
        )
        let first = try await store.saveSetupOperation(operation)
        let loaded = try #require(try await store.setupOperations().first)
        #expect(loaded.value.presetIDs[baseID.uuidString] == customID)

        operation.phase = .published
        _ = try await store.saveSetupOperation(operation, expectedVersion: first.version)
        await #expect(throws: ChauffeurError.self) {
            try await store.saveSetupOperation(operation, expectedVersion: first.version)
        }

        let operations = root.appendingPathComponent("onboarding/operations")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: operations)
        try FileManager.default.createSymbolicLink(at: operations, withDestinationURL: outside)
        await #expect(throws: ChauffeurError.self) { try await store.setupOperations() }
    }
}
