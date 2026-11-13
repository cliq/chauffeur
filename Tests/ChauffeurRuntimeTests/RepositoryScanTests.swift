import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct RepositoryChangeClassifierTests {
    let repository = UUID()
    let main = "/work/app"
    let linked = "/work/app-feature"
    var classifier: RepositoryChangeClassifier {
        RepositoryChangeClassifier(
            checkouts: [main: repository, linked: repository],
            gitDirectories: ["/work/app/.git": (repository, main), "/work/app/.git/worktrees/app-feature": (repository, linked)],
            unavailableSources: ["/work/notes"])
    }

    @Test func workingTreeEditsOnlyChangeThatCheckoutsStatus() {
        let result = classifier.classify(["/work/app-feature/Sources": []])
        #expect(result.checkouts == [linked] && result.repositories.isEmpty)
    }

    @Test func indexWritesChangeStatusButBranchMovesChangeTheInventory() {
        #expect(classifier.classify(["/work/app/.git/index": []]).checkouts == [main])
        #expect(classifier.classify(["/work/app/.git/worktrees/app-feature/index": []]) == .init(checkouts: [linked]))
        #expect(classifier.classify(["/work/app/.git/worktrees/app-feature/HEAD": []]).repositories == [repository])
        #expect(classifier.classify(["/work/app/.git/refs/heads/main": []]).repositories == [repository])
        #expect(classifier.classify(["/work/app/.git/packed-refs": []]).repositories == [repository])
        // A worktree Git registered that the last scan did not know about.
        #expect(classifier.classify(["/work/app/.git/worktrees/other/HEAD": []]).repositories == [repository])
    }

    @Test func submoduleMetadataOnlyChangesTheParentStatus() {
        #expect(classifier.classify(["/work/app/.git/modules/vendor/HEAD": []]) == .init(checkouts: [main]))
    }

    @Test func aCheckoutDirectoryAppearingOrDisappearingChangesTheInventory() {
        let removed = classifier.classify(["/work/app-feature": [.directoryChanged]])
        #expect(removed.repositories == [repository] && removed.checkouts.contains(linked))
        // Files written at the checkout's top level are only a status change.
        #expect(classifier.classify(["/work/app-feature": []]).repositories.isEmpty)
        #expect(classifier.classify(["/work/app-feature/.git": []]).repositories == [repository])
    }

    @Test func unrelatedPathsAndPlainFoldersAreReportedSeparately() {
        #expect(classifier.classify(["/elsewhere/file": []]) == .init())
        #expect(classifier.classify(["/work/notes/draft": []]) == .init(sources: ["/work/notes"]))
    }

    @Test func gitHousekeepingIsIgnored() {
        #expect(RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/index.lock"))
        #expect(RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/objects/ab/cdef"))
        #expect(RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/logs/HEAD"))
        #expect(RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/FETCH_HEAD"))
        #expect(!RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/HEAD"))
        #expect(!RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/refs/heads/main"))
        // User-chosen names that match housekeeping folders still count.
        #expect(!RepositoryChangeClassifier.isIgnorableMetadata("/work/hooks/app/.git/HEAD"))
        #expect(!RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/refs/heads/feature/logs/x"))
        #expect(!RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/worktrees/objects/HEAD"))
        #expect(RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/worktrees/feature/logs/HEAD"))
        #expect(RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/worktrees/feature/ORIG_HEAD"))
        // Branches may be named like housekeeping files.
        #expect(!RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/refs/heads/ORIG_HEAD"))
        #expect(!RepositoryChangeClassifier.isIgnorableMetadata("/work/app/.git/refs/heads/gc.log"))
        #expect(RepositoryChangeClassifier.isInsideGitMetadata("/work/app/.git/HEAD"))
        #expect(!RepositoryChangeClassifier.isInsideGitMetadata("/work/app/.gitignore"))
        #expect(!RepositoryChangeClassifier.isInsideGitMetadata("/work/app/.github/workflows"))
    }
}

#if os(macOS)
/// The periodic scan runs Git only where FSEvents reported changes.
@Suite(.serialized) struct ChangeDrivenRepositoryScanTests {
    @Test func unchangedRepositoriesAreNotReadAgainAndChangesStillShow() async throws {
        let fixture = try await ScanFixture.make(); defer { fixture.cleanup() }
        let worktree = try await fixture.runtime.createWorktree(fixture.request).value
        await fixture.runtime.reconcileWorktrees()
        // Let events from creating the fixture settle.
        try await Task.sleep(for: .seconds(2))
        await fixture.runtime.reconcileWorktrees(onlyChanged: true)
        try await Task.sleep(for: .seconds(2))

        let before = await fixture.runtime.worktrees.gitInvocations
        await fixture.runtime.reconcileWorktrees(onlyChanged: true)
        #expect(await fixture.runtime.worktrees.gitInvocations == before)
        #expect(try await fixture.entry(worktree.path)?.hasUncommittedChanges == false)

        // A new file shows as uncommitted work without reading the rest of the repository.
        try Data("draft".utf8).write(to: URL(fileURLWithPath: worktree.path).appendingPathComponent("draft.txt"))
        let dirty = try await fixture.poll { try await fixture.entry(worktree.path)?.hasUncommittedChanges == true }
        #expect(dirty)

        // A commit moves the branch, which changes its count of unmerged commits.
        for args in [["add", "draft.txt"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Draft"]] {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", worktree.path] + args)
            try #require(result.status == 0)
        }
        let committed = try await fixture.poll {
            let entry = try await fixture.entry(worktree.path)
            return entry?.unmergedCommits == 1 && entry?.hasUncommittedChanges == false
        }
        #expect(committed)
    }
}

private struct ScanFixture {
    let root: URL
    let runtime: RuntimeCoordinator
    let request: WorktreeCreationRequest
    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-scan-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "core.hooksPath", "/dev/null"], ["config", "commit.gpgsign", "false"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"]] {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + args)
            guard result.status == 0 else { throw ChauffeurError("fixture_git", result.error) }
        }
        let runtime = try RuntimeCoordinator(root: root, ctlPath: "/bin/false", environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": root.path])
        let set = PresetSet(name: "Scan fixture")
        var project = Project(name: "Scan fixture", presetSetID: set.id)
        project.addFolder(ProjectFolder(path: repo.path))
        try await runtime.store.save(set); try await runtime.store.save(project)
        try await runtime.start()
        return Self(root: root, runtime: runtime, request: WorktreeCreationRequest(projectID: project.id, folderID: project.folders[0].id, branch: "task/scan", baseRef: "HEAD"))
    }
    func entry(_ path: String) async throws -> GitWorktree? {
        let inventories = try await runtime.snapshot()["repositoryInventories"].decode([RepositoryInventory].self)
        return inventories.flatMap(\.entries).first { $0.path == path }
    }
    /// Runs periodic scans until `condition` holds, allowing for FSEvents latency.
    func poll(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            await runtime.reconcileWorktrees(onlyChanged: true)
            if try await condition() { return true }
        }
        return false
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
#endif
