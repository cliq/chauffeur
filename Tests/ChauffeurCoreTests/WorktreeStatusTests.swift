import Foundation
import Testing
import ChauffeurCore

struct WorktreeStatusTests {
    @Test func deletionChecklistMarksEachFactSafeOrLossy() throws {
        typealias Item = WorktreeDeletionPreview.Item
        let clean = WorktreeDeletionPreview(hasChanges: false, unmergedCommits: 0, baseBranch: "main")
        #expect(clean.items(branch: "task", finishedSessions: 0, checkoutMissing: false) == [
            Item(.safe, "No uncommitted changes"), Item(.safe, "All commits are merged into main"),
            Item(.safe, "No session history is affected")])
        // A merged branch is offered as a choice instead of a footnote.
        #expect(clean.offersBranchDeletion(branch: "task", checkoutMissing: false))
        #expect(!clean.offersBranchDeletion(branch: "", checkoutMissing: false))
        #expect(!clean.offersBranchDeletion(branch: "task", checkoutMissing: true))
        // Unmerged commits that already live on a remote lose nothing.
        let pushed = WorktreeDeletionPreview(hasChanges: false, unmergedCommits: 4, baseBranch: "main", unpushedCommits: 0, remoteBranch: "origin/task")
        #expect(pushed.isPushed && !pushed.offersBranchDeletion(branch: "task", checkoutMissing: false))
        #expect(pushed.items(branch: "task", finishedSessions: 2, checkoutMissing: false) == [
            Item(.safe, "No uncommitted changes"), Item(.safe, "4 commits not merged into main, all pushed to origin/task"),
            Item(.note, "Branch task is kept"), Item(.note, "2 finished sessions and their terminal history are deleted")])
        let partlyPushed = WorktreeDeletionPreview(hasChanges: true, unmergedCommits: 4, baseBranch: "main", unpushedCommits: 1, remoteBranch: "origin/task")
        #expect(!partlyPushed.isPushed)
        #expect(partlyPushed.items(branch: "task", finishedSessions: 0, checkoutMissing: false).map(\.severity) == [.loss, .loss, .note, .safe])
        #expect(partlyPushed.items(branch: "task", finishedSessions: 0, checkoutMissing: false)[1].text == "4 commits not merged into main, 1 not pushed to origin/task")
        let local = WorktreeDeletionPreview(hasChanges: false, unmergedCommits: 1, baseBranch: "main")
        #expect(local.items(branch: "task", finishedSessions: 0, checkoutMissing: false)[1] == Item(.loss, "1 commit not merged into main, not pushed to any remote"))
        // Submodule repositories go with the checkout; commits only they hold are lost.
        var submodules = WorktreeDeletionPreview(hasChanges: false, unmergedCommits: 0, baseBranch: "main", submodules: [.init(path: "lib", localCommits: 0)])
        #expect(!submodules.requiresDiscard)
        #expect(submodules.items(branch: "", finishedSessions: 0, checkoutMissing: false) == [
            Item(.safe, "No uncommitted changes"), Item(.safe, "All commits are merged into main"),
            Item(.safe, "Submodule commits exist outside this worktree"), Item(.safe, "No session history is affected")])
        submodules.submodules = [.init(path: "lib", localCommits: 0), .init(path: "vendor/ui", localCommits: 2)]
        #expect(submodules.requiresDiscard)
        #expect(submodules.items(branch: "", finishedSessions: 0, checkoutMissing: false).filter { $0.severity == .loss } == [
            Item(.loss, "Submodule vendor/ui has 2 commits only in this worktree")])
        // Unknown merge state and a detached HEAD are stated, not guessed.
        #expect(WorktreeDeletionPreview(hasChanges: false).items(branch: "", finishedSessions: 0, checkoutMissing: false) == [
            Item(.safe, "No uncommitted changes"), Item(.note, "Merge state is unknown"), Item(.safe, "No session history is affected")])
        // History removal is informational even when the checkout is already gone.
        #expect(WorktreeDeletionPreview(hasChanges: true, unmergedCommits: 3).items(branch: "task", finishedSessions: 1, checkoutMissing: true) == [
            Item(.note, "The checkout is already gone"), Item(.note, "1 finished session and their terminal history are deleted")])
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
