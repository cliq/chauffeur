import Foundation
import Testing
@testable import ChauffeurCore

struct InventoryReadinessTests {
    @Test func unreportedFoldersArePendingRatherThanEmpty() {
        // A project saved a moment ago has no observation until the next scan.
        #expect(InventoryReadiness.of(folderPath: "/repos/new", inventories: nil) == .pending)
        #expect(InventoryReadiness.of(folderPath: "/repos/new", inventories: []) == .pending)
        let other = RepositoryInventory(sourcePath: "/repos/other", status: .available)
        #expect(InventoryReadiness.of(folderPath: "/repos/new", inventories: [other]) == .pending)
    }

    @Test func observedFoldersReportTheirScanOutcome() {
        var grouped = RepositoryInventory(sourcePath: "/repos/main", status: .available)
        grouped.sourcePaths = ["/repos/main", "/repos/main-worktree"]
        #expect(InventoryReadiness.of(folderPath: "/repos/main-worktree", inventories: [grouped]) == .ready)
        #expect(InventoryReadiness.of(folderPath: "/repos/plain", inventories: [RepositoryInventory(sourcePath: "/repos/plain", status: .notRepository)]) == .notRepository)
        var failed = RepositoryInventory(sourcePath: "/repos/broken", status: .failed)
        failed.error = ChauffeurError("git_failed", "git worktree list exited with status 128")
        #expect(InventoryReadiness.of(folderPath: "/repos/broken", inventories: [failed]) == .failed("git worktree list exited with status 128"))
        #expect(InventoryReadiness.of(folderPath: "/repos/gone", inventories: [RepositoryInventory(sourcePath: "/repos/gone", status: .missing)]) == .failed("The folder is missing"))
    }
}
