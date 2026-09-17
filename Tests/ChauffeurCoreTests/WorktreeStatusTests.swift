import Foundation
import Testing
import ChauffeurCore

struct WorktreeStatusTests {
    @Test func deletionPreviewWarnsAboutEachKindOfLoss() throws {
        #expect(WorktreeDeletionPreview(hasChanges: false).warnings.isEmpty)
        #expect(WorktreeDeletionPreview(hasChanges: false).warningText == "")
        #expect(WorktreeDeletionPreview(hasChanges: false, unmergedCommits: 0, baseBranch: "main").warnings.isEmpty)
        let dirty = WorktreeDeletionPreview(hasChanges: true).warnings
        #expect(dirty.count == 1 && dirty[0].contains("permanently lost"))
        let unmerged = WorktreeDeletionPreview(hasChanges: false, unmergedCommits: 1, baseBranch: "main").warnings
        #expect(unmerged == ["Its branch has 1 commit not merged into main. The branch is kept, but it no longer has a checkout."])
        let both = WorktreeDeletionPreview(hasChanges: true, unmergedCommits: 3)
        #expect(both.warnings.count == 2 && both.warnings[1].hasPrefix("Its branch has 3 commits not merged."))
        #expect(both.warningText.hasSuffix("\n\n"))
    }

    @Test func previewAndInventoryDecodeWithoutStatusFields() throws {
        // Older runtimes report only `hasChanges`; older inventories carry no status.
        let preview = try JSONCoding.decode(WorktreeDeletionPreview.self, from: Data(#"{"hasChanges": true}"#.utf8))
        #expect(preview == WorktreeDeletionPreview(hasChanges: true))
        let entry = try JSONCoding.decode(GitWorktree.self, from: Data(#"{"path": "/tmp/tree", "commit": "abc", "branch": "task", "locked": false, "prunable": false}"#.utf8))
        #expect(entry.hasUncommittedChanges == nil && entry.unmergedCommits == nil && entry.baseBranch == nil)
        var annotated = entry
        annotated.hasUncommittedChanges = true; annotated.unmergedCommits = 2; annotated.baseBranch = "main"
        let restored = try JSONCoding.decode(GitWorktree.self, from: JSONCoding.encode(annotated))
        #expect(restored == annotated)
    }
}
