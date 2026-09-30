import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct WorktreeToolTests {
    @Test func agentsCreateWorktreesInTheirRepositoryAndRemoveThemSafely() async throws {
        // Managed checkouts live outside the repository, as in the app.
        let checkouts = URL(fileURLWithPath: "/tmp/chauffeur-tool-worktrees-\(UUID())")
        defer { try? FileManager.default.removeItem(at: checkouts) }
        let fixture = try await LaunchFixture.make(worktreeRoot: checkouts); defer { fixture.cleanup() }
        for args in [["init", "-b", "main"], ["config", "core.hooksPath", "/dev/null"], ["config", "commit.gpgsign", "false"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"]] {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", fixture.root.path] + args)
            try #require(result.status == 0)
        }
        let session = try await fixture.runtime.launch(fixture.request)
        let token = try await fixture.runtime.ledger.issueGrant(sessionID: session.id)
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            try await fixture.runtime.callTool(token: token, name: name, arguments: .object(arguments))
        }

        let created = try await call("chauffeur_create_worktree", ["branch": .string("tool/one"), "retryKey": .string("one")])
        let path = try #require(created["path"].string)
        #expect(created["folderID"].string == fixture.request.folderID.uuidString)
        #expect(created["branch"].string == "tool/one" && created["baseBranch"].string == "main")
        #expect(FileManager.default.fileExists(atPath: path + "/.git"))
        let retried = try await call("chauffeur_create_worktree", ["branch": .string("tool/one"), "retryKey": .string("one")])
        #expect(retried["worktreeID"] == created["worktreeID"])

        FileManager.default.createFile(atPath: path + "/scratch.txt", contents: Data("work".utf8))
        do {
            _ = try await call("chauffeur_remove_worktree", ["worktreeID": created["worktreeID"]])
            Issue.record("Uncommitted files should block removal")
        } catch let error as ChauffeurError { #expect(error.code == "dirty_worktree") }
        #expect(FileManager.default.fileExists(atPath: path + "/scratch.txt"))

        let removed = try await call("chauffeur_remove_worktree", ["worktreeID": created["worktreeID"], "discardChanges": .bool(true)])
        #expect(removed["removed"] == .bool(true))
        #expect(!FileManager.default.fileExists(atPath: path))
        do {
            _ = try await call("chauffeur_remove_worktree", ["worktreeID": created["worktreeID"]])
            Issue.record("A removed worktree is no longer registered")
        } catch let error as ChauffeurError { #expect(error.code == "missing_worktree") }

        let external = fixture.path("external")
        let added = try await ProcessRunner.run("/usr/bin/git", ["-C", fixture.root.path, "worktree", "add", "-b", "external", external.path, "HEAD"])
        try #require(added.status == 0)
        let registered = try await fixture.runtime.handle(IPCRequest("registerWorktree", params: .object([
            "projectID": .string(fixture.request.projectID.uuidString), "folderID": .string(fixture.request.folderID.uuidString), "path": .string(Paths.canonical(external.path))
        ]))).decode(Stored<Worktree>.self).value
        do {
            _ = try await call("chauffeur_remove_worktree", ["worktreeID": .string(registered.id.uuidString)])
            Issue.record("External checkouts are the user's to remove")
        } catch let error as ChauffeurError { #expect(error.code == "external_worktree") }
        #expect(FileManager.default.fileExists(atPath: external.path))
    }
}
