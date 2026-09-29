import Foundation
import Testing
@testable import ChauffeurCore

struct SnapshotChangeTests {
    private func snapshot(observedAt: String, bytes: Double, branch: String = "main") -> JSONValue {
        .object([
            "sessions": .array([]),
            "snapshotStorage": .object(["bytes": .number(bytes), "files": .number(3)]),
            "repositoryInventories": .array([.object(["sourcePath": .string("/repo"), "observedAt": .string(observedAt),
                "entries": .array([.object(["path": .string("/repo"), "branch": .string(branch)])])])]),
        ])
    }

    @Test func rescansAndStorageDriftKeepTheSameKey() throws {
        let first = try SnapshotChange.key(snapshot(observedAt: "2026-09-29T10:00:00Z", bytes: 100))
        let rescanned = try SnapshotChange.key(snapshot(observedAt: "2026-09-29T10:00:05Z", bytes: 250))
        #expect(first == rescanned)
    }

    @Test func inventoryContentChangesTheKey() throws {
        let first = try SnapshotChange.key(snapshot(observedAt: "2026-09-29T10:00:00Z", bytes: 100))
        let switched = try SnapshotChange.key(snapshot(observedAt: "2026-09-29T10:00:00Z", bytes: 100, branch: "feature"))
        #expect(first != switched)
    }
}
