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

    @Test func checkoutNotesAreSharedWithAgentsAndLeaveWithTheirWorktree() async throws {
        let checkouts = URL(fileURLWithPath: "/tmp/chauffeur-note-worktrees-\(UUID())")
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
        func saveFromApp(path: String, text: String, version: String?) async throws -> JSONValue {
            try await fixture.runtime.handle(IPCRequest("saveCheckoutNote", params: .object([
                "projectID": .string(fixture.request.projectID.uuidString), "folderID": .string(fixture.request.folderID.uuidString),
                "path": .string(path), "text": .string(text), "version": version.map(JSONValue.string) ?? .null
            ])))
        }
        func notes() async -> [Stored<CheckoutNote>] { await fixture.runtime.store.reload().checkoutNotes }

        // The caller's own checkout is the default.
        let empty = try await call("chauffeur_get_checkout_note", [:])
        #expect(empty["note"] == .null && empty["path"].string == Paths.canonical(session.launch.workingDirectory))
        let written = try await call("chauffeur_set_checkout_note", ["note": .string("Resume at the parser")])
        #expect(written["note"].string == "Resume at the parser" && written["author"].string == session.title)

        // The app edits from the version it saw, so the agent's note is not overwritten blindly.
        let mainPath = try #require(written["path"].string)
        do {
            _ = try await saveFromApp(path: mainPath, text: "From the app", version: nil)
            Issue.record("A note the app did not see should conflict")
        } catch let error as ChauffeurError { #expect(error.code == "edit_conflict") }
        let current = try #require(await notes().first)
        let edited = try await saveFromApp(path: mainPath, text: "From the app", version: current.version).decode(Stored<CheckoutNote>.self)
        #expect(edited.value.id == current.value.id && edited.value.text == "From the app" && edited.value.authorTitle == nil)
        #expect(try await call("chauffeur_get_checkout_note", ["path": .string(mainPath)])["author"].string == "the user")
        #expect(try await saveFromApp(path: mainPath, text: "", version: edited.version) == .null)
        #expect(await notes().isEmpty)

        do {
            _ = try await call("chauffeur_set_checkout_note", ["note": .string("Elsewhere"), "path": .string("/")])
            Issue.record("Paths outside the project's checkouts have no note")
        } catch let error as ChauffeurError { #expect(error.code == "missing_checkout") }

        // A worktree's note is removed with it, so a later checkout at that path starts clean.
        let created = try await call("chauffeur_create_worktree", ["branch": .string("note/one"), "retryKey": .string("note")])
        let worktreePath = try #require(created["path"].string)
        _ = try await call("chauffeur_set_checkout_note", ["note": .string("Half-way through"), "path": .string(worktreePath + "/.git")])
        #expect(await notes().map(\.value.path) == [Paths.canonical(worktreePath)])
        _ = try await call("chauffeur_remove_worktree", ["worktreeID": created["worktreeID"]])
        #expect(await notes().isEmpty)

        // Delete Worktree in the app takes the same note with it.
        let deleted = try await call("chauffeur_create_worktree", ["branch": .string("note/two"), "retryKey": .string("note-two")])
        let deletedPath = try #require(deleted["path"].string)
        _ = try await saveFromApp(path: deletedPath, text: "Parked", version: nil)
        _ = try await fixture.runtime.handle(IPCRequest("deleteWorktree", params: .object([
            "projectID": .string(fixture.request.projectID.uuidString), "folderID": .string(fixture.request.folderID.uuidString), "path": .string(deletedPath)
        ])))
        #expect(await notes().isEmpty)
    }
}
