import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct WorktreeTests {
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
