import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct WorktreeTests {
    @Test func legacyResumeRequiresAnIdentityForEveryPathAndDamagedGitIsNotAPlainFolder() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-legacy-resume-\(UUID())")
        let repo = root.appendingPathComponent("repo"), plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #require(try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "init", "-b", "main"]).status == 0)
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let set = PresetSet(name: "Fixture"), preset = AgentPreset(setID: UUID(), name: "Fixture", kind: .claude, executable: "/bin/cat", configurationDirectory: root.path)
        var launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat", executableVersion: "fixture", workingDirectory: Paths.canonical(repo.path), additionalPaths: [])
        launch.gitWorktreeIdentities = [try await manager.identity(at: repo.path)]
        // Decoding a snapshot written before checkout bindings remains valid.
        let decoded = try JSONCoding.decode(LaunchSnapshot.self, from: JSONCoding.encode(launch))
        #expect(decoded.checkoutIdentities == nil)
        try await manager.validateResume(decoded)
        launch.additionalPaths = [Paths.canonical(plain.path)]
        var code: String?
        do { try await manager.validateResume(launch) } catch let error as ChauffeurError { code = error.code }
        #expect(code == "checkout_unverified")
        launch.additionalPaths = []; launch.gitWorktreeIdentities = [UUID()]
        code = nil
        do { try await manager.validateResume(launch) } catch let error as ChauffeurError { code = error.code }
        #expect(code == "checkout_changed")
        #expect(try await manager.checkoutIdentity(at: plain.path).gitIdentity == nil)
        try Data("gitdir: /nonexistent-chauffeur-fixture\n".utf8).write(to: plain.appendingPathComponent(".git"))
        await #expect(throws: ChauffeurError.self) { try await manager.checkoutIdentity(at: plain.path) }
        try FileManager.default.removeItem(at: plain.appendingPathComponent(".git"))
        try FileManager.default.createDirectory(at: plain.appendingPathComponent(".git"), withIntermediateDirectories: true)
        await #expect(throws: ChauffeurError.self) { try await manager.checkoutIdentity(at: plain.path) }
    }

    @Test func repositoryIdentitySurvivesMovingTheMainRepository() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-repo-move-\(UUID())").resolvingSymlinksInPath()
        let original = root.appendingPathComponent("original"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ directory: URL, _ args: [String]) async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", directory.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + args)
            try #require(result.status == 0, "Git fixture failed: \(result.error)")
        }
        try await git(original, ["init", "-b", "main"])
        try await git(original, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"])
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let tree = try await manager.create(projectID: UUID(), folder: ProjectFolder(path: original.path), branch: "task/move", baseRef: "HEAD")
        try FileManager.default.moveItem(at: original, to: moved)
        try await git(moved, ["worktree", "repair"])
        #expect(try await manager.repositoryID(at: moved.path) == tree.repositoryID)
        let updated = await manager.reconciled(tree, inventory: manager.observe(at: moved.path))
        #expect(updated.availability == .available && updated.id == tree.id && updated.baseCommit == tree.baseCommit)
        #expect(updated.repositoryPath == Paths.canonical(moved.path))
        #expect(updated.gitIdentity == tree.gitIdentity)
        try await manager.remove(updated, liveSessions: [])
        #expect(!FileManager.default.fileExists(atPath: tree.path))
    }

    @Test func inventoryRecognizesMovesAndReplacementsWithoutRewritingBaseCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-inventory-\(UUID())")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + args)
            #expect(result.status == 0, "Git fixture command failed: \(result.error)")
        }
        try await git(["init", "-b", "main"])
        try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"])
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let first = try await manager.create(projectID: UUID(), folder: ProjectFolder(path: repo.path), branch: "refs/heads/original", baseRef: "main")
        #expect(first.gitIdentity != nil)
        let moved = URL(fileURLWithPath: first.path).deletingLastPathComponent().appendingPathComponent("moved\ncheckout")
        try await git(["worktree", "move", first.path, moved.path])
        let observation = await manager.observe(at: repo.path)
        let updated = await manager.reconciled(first, inventory: observation)
        #expect(updated.id == first.id && updated.gitIdentity == first.gitIdentity)
        #expect(updated.path == Paths.canonical(moved.path) && updated.managed && updated.availability == .available)
        #expect(updated.baseCommit == first.baseCommit)
        #expect(updated.branch == "refs/heads/original")
        // An external replacement at the same path must not inherit ownership.
        try await git(["worktree", "remove", moved.path])
        try await git(["worktree", "add", "-b", "replacement", moved.path, "main"])
        let replaced = await manager.observe(at: repo.path)
        #expect(await manager.reconciled(updated, inventory: replaced).availability == .missing)
        await #expect(throws: ChauffeurError.self) { try await manager.remove(updated, liveSessions: []) }
        #expect(FileManager.default.fileExists(atPath: moved.path))
        // A move out of managed storage becomes an external registration.
        var registered = updated
        registered.gitIdentity = replaced.entries.first { $0.path == updated.path }?.gitIdentity
        let outside = root.appendingPathComponent("external")
        try await git(["worktree", "move", moved.path, outside.path])
        let external = await manager.reconciled(registered, inventory: manager.observe(at: repo.path))
        #expect(external.id == registered.id && !external.managed && external.availability == .available)
        #expect(external.path == Paths.canonical(outside.path))
        #expect(await manager.observe(at: root.path).status == .notRepository)
        #expect(await manager.observe(at: root.appendingPathComponent("missing").path).status == .missing)
    }
    @Test func deletionPreservesUniqueCommitsAndRemovesIgnoredFiles() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-delete-\(UUID())")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ path: String, _ args: [String]) async throws -> CommandResult {
            try await ProcessRunner.run("/usr/bin/git", ["-C", path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"] + args)
        }
        try #require(try await git(repo.path, ["init", "-b", "main"]).status == 0)
        try Data("ignored.txt\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try #require(try await git(repo.path, ["add", ".gitignore"]).status == 0)
        try #require(try await git(repo.path, ["commit", "-m", "Initial"]).status == 0)
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let tree = try await manager.create(projectID: UUID(), folder: ProjectFolder(path: repo.path), branch: "task/unique", baseRef: "HEAD")
        #expect(try await !manager.hasChanges(at: tree.path))
        try #require(try await git(tree.path, ["commit", "--allow-empty", "-m", "Unique"]).status == 0)
        try Data("local".utf8).write(to: URL(fileURLWithPath: tree.path).appendingPathComponent("ignored.txt"))
        #expect(try await !manager.hasChanges(at: tree.path))
        #expect(try await manager.changedFiles(at: tree.path).isEmpty)
        try await manager.remove(tree, liveSessions: [])
        #expect(!FileManager.default.fileExists(atPath: tree.path))
        #expect(try await git(repo.path, ["show-ref", "--verify", "refs/heads/task/unique"]).status == 0)
        // Another branch protects the commits even when main has not merged them.
        try #require(try await git(repo.path, ["branch", "saved", "task/unique"]).status == 0)
        await manager.deleteBranchIfUnused("task/unique", repository: repo.path)
        #expect(try await git(repo.path, ["show-ref", "--verify", "refs/heads/task/unique"]).status != 0)
        await manager.deleteBranchIfUnused("main", repository: repo.path)
        #expect(try await git(repo.path, ["show-ref", "--verify", "refs/heads/main"]).status == 0)
    }

    @Test func independentCheckoutsAndSafeRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-worktrees-\(UUID())")
        let repo = root.appendingPathComponent("répo space")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws -> CommandResult { try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + args) }
        #expect(try await git(["init", "-b", "main"]).status == 0)
        try Data("original\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        #expect(try await git(["add", "file.txt"]).status == 0)
        #expect(try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Initial"]).status == 0)
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let folder = ProjectFolder(path: repo.path), projectID = UUID()
        let first = try await manager.create(projectID: projectID, folder: folder, branch: "task/one", baseRef: "main")
        let second = try await manager.create(projectID: projectID, folder: folder, branch: "task/two", baseRef: "main")
        #expect(first.path != second.path)
        #expect(first.baseCommit == second.baseCommit)
        #expect(try await manager.inventory(at: repo.path).count == 3)
        try Data("changed\n".utf8).write(to: URL(fileURLWithPath: first.path).appendingPathComponent("file.txt"))
        #expect(try String(contentsOf: URL(fileURLWithPath: second.path).appendingPathComponent("file.txt"), encoding: .utf8) == "original\n")
        await #expect(throws: ChauffeurError.self) { try await manager.remove(first, liveSessions: []) }
        #expect(try await manager.changedFiles(at: first.path) == [.init(path: "file.txt", status: " M")])
        try Data("untracked".utf8).write(to: URL(fileURLWithPath: second.path).appendingPathComponent("new.txt"))
        #expect(try await manager.changedFiles(at: second.path) == [.init(path: "new.txt", status: "??")])
        await #expect(throws: ChauffeurError.self) { try await manager.remove(second, liveSessions: []) }
        try FileManager.default.removeItem(atPath: second.path + "/new.txt")
        let set = PresetSet(name: "Fixture"), preset = AgentPreset(setID: UUID(), name: "Fixture", kind: .codex, executable: "/bin/cat", configurationDirectory: root.path)
        let snapshot = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat", executableVersion: "fixture", workingDirectory: second.path, additionalPaths: [])
        let live = Session(projectID: projectID, groupID: UUID(), title: "Live", launch: snapshot, folderID: folder.id)
        await #expect(throws: ChauffeurError.self) { try await manager.remove(second, liveSessions: [live]) }
        try await manager.remove(second, liveSessions: [])
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(try await git(["show-ref", "--verify", "refs/heads/task/two"]).status != 0)
        var external = first; external.managed = false
        await #expect(throws: ChauffeurError.self) { try await manager.remove(external, liveSessions: []) }
        await #expect(throws: ChauffeurError.self) { try await manager.create(projectID: projectID, folder: folder, branch: "task/one", baseRef: "main") }
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(try await manager.hasChanges(at: first.path))
        try await manager.remove(first, liveSessions: [], discardChanges: true)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try await git(["show-ref", "--verify", "refs/heads/task/one"]).status != 0)
    }
}

struct WorktreeGitStatusTests {
    private static func git(_ directory: URL, _ args: [String]) async throws {
        let result = try await ProcessRunner.run("/usr/bin/git", ["-C", directory.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"] + args)
        try #require(result.status == 0, "Git fixture failed: \(result.error)")
    }

    @Test func createdWorktreesRememberTheirStartingBranch() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-base-branch-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Self.git(repo, ["init", "-b", "main"])
        try await Self.git(repo, ["commit", "--allow-empty", "-m", "Initial"])
        try await Self.git(repo, ["branch", "develop"])
        try await Self.git(repo, ["tag", "v1"])
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let folder = ProjectFolder(path: repo.path)
        #expect(try await manager.create(projectID: UUID(), folder: folder, branch: "from-head", baseRef: "HEAD").baseBranch == "main")
        #expect(try await manager.create(projectID: UUID(), folder: folder, branch: "from-develop", baseRef: "develop").baseBranch == "develop")
        // A tag or commit is a starting point, not a branch to merge back into.
        #expect(try await manager.create(projectID: UUID(), folder: folder, branch: "from-tag", baseRef: "v1").baseBranch == nil)
    }

    @Test func inventoryReportsUncommittedChangesAndUnmergedCommits() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-git-status-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("build/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        try await Self.git(repo, ["init", "-b", "main"])
        try await Self.git(repo, ["add", ".gitignore"])
        try await Self.git(repo, ["commit", "-m", "Initial"])
        try await Self.git(repo, ["branch", "develop"])
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let folder = ProjectFolder(path: repo.path)
        let fromMain = try await manager.create(projectID: UUID(), folder: folder, branch: "task/main", baseRef: "HEAD")
        let fromDevelop = try await manager.create(projectID: UUID(), folder: folder, branch: "task/develop", baseRef: "develop")
        let external = root.appendingPathComponent("external")
        try await Self.git(repo, ["worktree", "add", "-b", "external", external.path, "HEAD"])
        let bases = [fromMain.path: fromMain.baseBranch, fromDevelop.path: fromDevelop.baseBranch]
        func annotated() async throws -> [String: GitWorktree] {
            let entries = await manager.annotated(try await manager.inventory(at: repo.path)) { bases[$0.path] ?? nil }
            return Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        }
        var status = try await annotated()
        let mainPath = Paths.canonical(repo.path)
        #expect(status[mainPath]?.hasUncommittedChanges == false && status[mainPath]?.unmergedCommits == nil && status[mainPath]?.baseBranch == nil)
        for path in [fromMain.path, fromDevelop.path, Paths.canonical(external.path)] {
            #expect(status[path]?.hasUncommittedChanges == false, "\(path)")
            #expect(status[path]?.unmergedCommits == 0, "\(path)")
        }
        #expect(status[fromMain.path]?.baseBranch == "main")
        #expect(status[fromDevelop.path]?.baseBranch == "develop")
        // A worktree Chauffeur did not create is measured against the main checkout's branch.
        #expect(status[Paths.canonical(external.path)]?.baseBranch == "main")

        // Ignored files are not pending work; untracked and modified files are.
        let ignored = URL(fileURLWithPath: fromMain.path).appendingPathComponent("build")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("out".utf8).write(to: ignored.appendingPathComponent("artifact"))
        try Data("note".utf8).write(to: URL(fileURLWithPath: fromDevelop.path).appendingPathComponent("notes.txt"))
        status = try await annotated()
        #expect(status[fromMain.path]?.hasUncommittedChanges == false)
        #expect(status[fromDevelop.path]?.hasUncommittedChanges == true)
        #expect(try await manager.hasChanges(at: fromMain.path) == false)

        // Commits count against the starting branch, not the main checkout.
        try await Self.git(URL(fileURLWithPath: fromDevelop.path), ["add", "notes.txt"])
        try await Self.git(URL(fileURLWithPath: fromDevelop.path), ["commit", "-m", "Notes"])
        try await Self.git(URL(fileURLWithPath: fromDevelop.path), ["commit", "--allow-empty", "-m", "More"])
        try await Self.git(repo, ["commit", "--allow-empty", "-m", "Main moves on"])
        status = try await annotated()
        #expect(status[fromDevelop.path]?.unmergedCommits == 2)
        #expect(status[fromDevelop.path]?.hasUncommittedChanges == false)
        #expect(status[fromMain.path]?.unmergedCommits == 0)
        // Merging into the base clears the count; a deleted base reports nothing.
        try await Self.git(repo, ["checkout", "develop"])
        try await Self.git(repo, ["merge", "--ff-only", "task/develop"])
        try await Self.git(repo, ["checkout", "main"])
        status = try await annotated()
        #expect(status[fromDevelop.path]?.unmergedCommits == 0)
        try await Self.git(repo, ["branch", "-D", "develop"])
        status = try await annotated()
        #expect(status[fromDevelop.path]?.unmergedCommits == nil && status[fromDevelop.path]?.baseBranch == "develop")
    }
}

struct WorktreeRootTests {
    @Test func newCheckoutsUseTheCurrentRootWhileLegacyCheckoutsStayManaged() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-worktree-root-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"] + args)
            try #require(result.status == 0, "Git fixture failed: \(result.error)")
        }
        try await git(["init", "-b", "main"])
        try await git(["commit", "--allow-empty", "-m", "Initial"])
        let legacyRoot = root.appendingPathComponent("Application Support/worktrees"), newRoot = root.appendingPathComponent(".chauffeur/worktrees")
        let folder = ProjectFolder(path: repo.path)
        // A checkout created before the root moved.
        let legacy = try await WorktreeManager(root: legacyRoot).create(projectID: UUID(), folder: folder, branch: "legacy", baseRef: "HEAD")
        #expect(legacy.path.hasPrefix(Paths.canonical(legacyRoot.path) + "/"))
        let manager = WorktreeManager(root: newRoot, legacyRoots: [legacyRoot])
        let fresh = try await manager.create(projectID: UUID(), folder: folder, branch: "fresh", baseRef: "HEAD")
        #expect(fresh.path.hasPrefix(Paths.canonical(newRoot.path) + "/") && fresh.managed)
        #expect(!fresh.path.contains(" "))
        // Reconciliation keeps both managed; a checkout elsewhere becomes external.
        let inventory = await manager.observe(at: repo.path)
        #expect(await manager.reconciled(legacy, inventory: inventory).managed)
        #expect(await manager.reconciled(fresh, inventory: inventory).managed)
        var elsewhere = fresh; elsewhere.path = root.appendingPathComponent("elsewhere").path
        try FileManager.default.moveItem(atPath: fresh.path, toPath: elsewhere.path)
        try await git(["worktree", "repair", elsewhere.path])
        #expect(await !manager.reconciled(elsewhere, inventory: manager.observe(at: repo.path)).managed)
        // Legacy managed checkouts can still be removed without the external override.
        try await manager.remove(legacy, liveSessions: [])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        var code: String?
        do { try await manager.remove(elsewhere, liveSessions: []) } catch let error as ChauffeurError { code = error.code }
        #expect(code == "unmanaged_path")
    }
}

struct WorktreeRemoteStatusTests {
    @Test func pushStateFollowsTheUpstreamOrAnyRemoteBranchContainingHead() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-remote-status-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo"), remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ directory: URL, _ args: [String]) async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", directory.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"] + args)
            try #require(result.status == 0, "Git fixture failed: \(result.error)")
        }
        try await git(root, ["init", "--bare", "-b", "main", remote.path])
        try await git(repo, ["init", "-b", "main"])
        try await git(repo, ["commit", "--allow-empty", "-m", "Initial"])
        try await git(repo, ["remote", "add", "origin", remote.path])
        try await git(repo, ["push", "-q", "-u", "origin", "main"])
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"))
        let tree = try await manager.create(projectID: UUID(), folder: ProjectFolder(path: repo.path), branch: "task", baseRef: "HEAD")
        let checkout = URL(fileURLWithPath: tree.path)
        // No upstream and no remote branch contains the branch's tip: unknown.
        try await git(checkout, ["commit", "--allow-empty", "-m", "Work"])
        var status = await manager.remoteStatus(at: tree.path)
        #expect(status.remoteBranch == nil && status.unpushedCommits == nil)
        // Pushing with an upstream makes the branch fully pushed; new commits count as unpushed.
        try await git(checkout, ["push", "-q", "-u", "origin", "task"])
        status = await manager.remoteStatus(at: tree.path)
        #expect(status.remoteBranch == "origin/task" && status.unpushedCommits == 0)
        try await git(checkout, ["commit", "--allow-empty", "-m", "More"])
        status = await manager.remoteStatus(at: tree.path)
        #expect(status.remoteBranch == "origin/task" && status.unpushedCommits == 1)
        // Without an upstream, a remote branch that already contains HEAD still counts.
        try await git(checkout, ["push", "-q", "origin", "task:review"])
        try await git(checkout, ["branch", "--unset-upstream"])
        status = await manager.remoteStatus(at: tree.path)
        #expect(status.remoteBranch == "origin/review" && status.unpushedCommits == 0)
    }

    /// Git LFS is a checkout filter installed outside /usr/bin (Homebrew puts it in
    /// /opt/homebrew/bin). Creating a worktree must find it on the user's PATH.
    @Test func newWorktreesRunCheckoutFiltersFromTheUsersPath() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-filter-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo"), bin = root.appendingPathComponent("bin")
        for directory in [repo, bin] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let filter = bin.appendingPathComponent("fixture-filter")
        try "#!/bin/sh\nexec /bin/cat\n".write(to: filter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filter.path)
        func git(_ args: [String]) async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + args,
                                                     environment: ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": root.path])
            try #require(result.status == 0, "Git fixture failed: \(result.error)")
        }
        try await git(["init", "-b", "main"])
        // Like `git lfs install`: a required filter the checkout cannot skip.
        for (key, value) in [("filter.fixture.smudge", "fixture-filter"), ("filter.fixture.clean", "fixture-filter"), ("filter.fixture.required", "true")] {
            try await git(["config", key, value])
        }
        try "*.bin filter=fixture\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "payload\n".write(to: repo.appendingPathComponent("asset.bin"), atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Asset"])
        let folder = ProjectFolder(path: repo.path)

        let system = WorktreeManager(root: root.appendingPathComponent("system"))
        await #expect(throws: ChauffeurError.self, "Without the user's PATH the filter is missing, as reported") {
            _ = try await system.create(projectID: UUID(), folder: folder, branch: "feature/system", baseRef: "HEAD")
        }
        let manager = WorktreeManager(root: root.appendingPathComponent("managed"), searchPath: "\(bin.path):/usr/bin:/bin")
        let worktree = try await manager.create(projectID: UUID(), folder: folder, branch: "feature/lfs", baseRef: "HEAD")
        #expect(try String(contentsOf: URL(fileURLWithPath: worktree.path).appendingPathComponent("asset.bin"), encoding: .utf8) == "payload\n")
    }
}
