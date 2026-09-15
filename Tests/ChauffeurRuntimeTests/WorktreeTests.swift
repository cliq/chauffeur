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
        try Data("untracked".utf8).write(to: URL(fileURLWithPath: second.path).appendingPathComponent("new.txt"))
        await #expect(throws: ChauffeurError.self) { try await manager.remove(second, liveSessions: []) }
        try FileManager.default.removeItem(atPath: second.path + "/new.txt")
        let set = PresetSet(name: "Fixture"), preset = AgentPreset(setID: UUID(), name: "Fixture", kind: .codex, executable: "/bin/cat", configurationDirectory: root.path)
        let snapshot = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat", executableVersion: "fixture", workingDirectory: second.path, additionalPaths: [])
        let live = Session(projectID: projectID, groupID: UUID(), title: "Live", launch: snapshot, folderID: folder.id)
        await #expect(throws: ChauffeurError.self) { try await manager.remove(second, liveSessions: [live]) }
        try await manager.remove(second, liveSessions: [])
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(try await git(["show-ref", "--verify", "refs/heads/task/two"]).status == 0)
        var external = first; external.managed = false
        await #expect(throws: ChauffeurError.self) { try await manager.remove(external, liveSessions: []) }
        await #expect(throws: ChauffeurError.self) { try await manager.create(projectID: projectID, folder: folder, branch: "task/one", baseRef: "main") }
        #expect(FileManager.default.fileExists(atPath: first.path))
    }
}
