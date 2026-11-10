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

        // Discarding work needs a preview's confirmation, so the agent has seen what goes.
        do {
            _ = try await call("chauffeur_remove_worktree", ["worktreeID": created["worktreeID"], "discardChanges": .bool(true)])
            Issue.record("Discarding should need a confirmation")
        } catch let error as ChauffeurError { #expect(error.code == "confirmation_required") }
        let preview = try await call("chauffeur_preview_worktree_removal", ["worktreeID": created["worktreeID"], "discardChanges": .bool(true)])
        #expect(preview["yourCheckout"] == .bool(false) && preview["blockers"].array.isEmpty)
        let removed = try await call("chauffeur_remove_worktree", ["worktreeID": created["worktreeID"], "discardChanges": .bool(true), "confirmation": preview["confirmation"]])
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

    /// A repository with a session in its main checkout, a worktree created through the tool,
    /// and a second session working in that worktree.
    private struct SelfRemovalFixture {
        let fixture: LaunchFixture, checkouts: URL
        let worktreeID: JSONValue, path: String, worker: Session
        let call: (String, [String: JSONValue]) async throws -> JSONValue
        let callFromMain: (String, [String: JSONValue]) async throws -> JSONValue
        func cleanup() { fixture.cleanup(); try? FileManager.default.removeItem(at: checkouts) }
        func git(_ args: [String]) async throws -> Int32 { try await ProcessRunner.run("/usr/bin/git", ["-C", path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"] + args).status }

        static func make(branch: String) async throws -> Self {
            let checkouts = URL(fileURLWithPath: "/tmp/chauffeur-self-worktrees-\(UUID())")
            let fixture = try await LaunchFixture.make(worktreeRoot: checkouts)
            for args in [["init", "-b", "main"], ["config", "core.hooksPath", "/dev/null"], ["config", "commit.gpgsign", "false"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"]] {
                let result = try await ProcessRunner.run("/usr/bin/git", ["-C", fixture.root.path] + args)
                try #require(result.status == 0)
            }
            let main = try await fixture.runtime.launch(fixture.request)
            let mainToken = try await fixture.runtime.ledger.issueGrant(sessionID: main.id)
            let created = try await fixture.runtime.callTool(token: mainToken, name: "chauffeur_create_worktree", arguments: .object(["branch": .string(branch), "retryKey": .string(branch)]))
            var request = fixture.request; request.retryKey = UUID(); request.worktreeID = UUID(uuidString: created["worktreeID"].string ?? "")
            let worker = try await fixture.runtime.launch(request)
            let token = try await fixture.runtime.ledger.issueGrant(sessionID: worker.id)
            return SelfRemovalFixture(fixture: fixture, checkouts: checkouts, worktreeID: created["worktreeID"], path: try #require(created["path"].string), worker: worker,
                                      call: { name, arguments in try await fixture.runtime.callTool(token: token, name: name, arguments: .object(arguments)) },
                                      callFromMain: { name, arguments in try await fixture.runtime.callTool(token: mainToken, name: name, arguments: .object(arguments)) })
        }
    }

    private func code(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch let error as ChauffeurError { return error.code } catch { return "\(error)" }
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 where try await !condition() { try await Task.sleep(for: .milliseconds(200)) }
    }

    @Test func agentsSeeWhatRemovingTheirOwnWorktreeLosesThenRemoveItAsTheirSessionEnds() async throws {
        let setup = try await SelfRemovalFixture.make(branch: "tool/self"); defer { setup.cleanup() }
        #expect(try await setup.git(["commit", "--allow-empty", "-m", "Unmerged"]) == 0)
        FileManager.default.createFile(atPath: setup.path + "/scratch.txt", contents: Data("work".utf8))

        // With no worktreeID, the preview covers the caller's own checkout.
        let preview = try await setup.call("chauffeur_preview_worktree_removal", [:])
        #expect(preview["worktreeID"] == setup.worktreeID && preview["yourCheckout"] == .bool(true) && preview["endsYourSession"] == .bool(true))
        #expect(preview["lost"].array.compactMap(\.string).contains { $0.contains("Uncommitted") })
        #expect(preview["changedFiles"].array.compactMap(\.string) == ["Untracked: scratch.txt"])
        #expect(preview["branchOutcome"].string?.contains("deleteBranch=always") == true)
        #expect(preview["blockers"].array.compactMap(\.string).contains { $0.contains("discardChanges") })
        // The main checkout's session sees the worker blocking it.
        let fromMain = try await setup.callFromMain("chauffeur_preview_worktree_removal", ["worktreeID": setup.worktreeID])
        #expect(fromMain["yourCheckout"] == .bool(false) && fromMain["blockers"].array.compactMap(\.string).contains { $0.contains("must end first") })
        #expect(await code { _ = try await setup.callFromMain("chauffeur_remove_worktree", ["worktreeID": setup.worktreeID, "discardChanges": .bool(true)]) } == "active_worktree")
        #expect(await code { _ = try await setup.callFromMain("chauffeur_preview_worktree_removal", [:]) } == "missing_worktree")

        // Removing your own worktree always needs a matching, fresh confirmation.
        #expect(await code { _ = try await setup.call("chauffeur_remove_worktree", ["discardChanges": .bool(true)]) } == "confirmation_required")
        let options: [String: JSONValue] = ["discardChanges": .bool(true), "deleteBranch": .string("always")]
        let confirmed = try await setup.call("chauffeur_preview_worktree_removal", options)
        #expect(confirmed["blockers"].array.isEmpty && confirmed["lost"].array.count == 2)
        let confirmation = try #require(confirmed["confirmation"].string)
        #expect(await code { _ = try await setup.call("chauffeur_remove_worktree", ["discardChanges": .bool(true), "confirmation": .string(confirmation)]) } == "confirmation_stale")
        FileManager.default.createFile(atPath: setup.path + "/later.txt", contents: Data("more".utf8))
        #expect(await code { _ = try await setup.call("chauffeur_remove_worktree", options.merging(["confirmation": .string(confirmation)]) { $1 }) } == "confirmation_stale")
        try FileManager.default.removeItem(atPath: setup.path + "/later.txt")

        let scheduled = try await setup.call("chauffeur_remove_worktree", options.merging(["confirmation": .string(confirmation)]) { $1 })
        #expect(scheduled["scheduled"] == .bool(true) && scheduled["endsYourSession"] == .bool(true))
        // Nothing starts in the worktree while its session ends.
        var request = setup.fixture.request; request.retryKey = UUID(); request.worktreeID = UUID(uuidString: setup.worktreeID.string ?? "")
        #expect(await code { _ = try await setup.fixture.runtime.launch(request) } == "worktree_busy")

        // The record is unregistered last, after the checkout and branch are gone.
        try await waitUntil { await setup.fixture.runtime.store.reload().worktrees.first { $0.value.id.uuidString == setup.worktreeID.string }?.value.registered == false }
        #expect(!FileManager.default.fileExists(atPath: setup.path))
        let worker = try #require(await setup.fixture.runtime.store.reload().sessions.first { $0.value.id == setup.worker.id }?.value)
        #expect(!worker.state.isLive && worker.error == nil)
        let branch = try await ProcessRunner.run("/usr/bin/git", ["-C", setup.fixture.root.path, "rev-parse", "--verify", "--quiet", "refs/heads/tool/self"])
        #expect(branch.status != 0)
    }

    @Test func aWorktreeThatChangesAsItsSessionEndsIsKept() async throws {
        let setup = try await SelfRemovalFixture.make(branch: "tool/kept"); defer { setup.cleanup() }
        let confirmation = try #require(try await setup.call("chauffeur_preview_worktree_removal", [:])["confirmation"].string)
        _ = try await setup.call("chauffeur_remove_worktree", ["confirmation": .string(confirmation)])
        // Written after confirming, as a build the agent left running might.
        FileManager.default.createFile(atPath: setup.path + "/late.txt", contents: Data("late".utf8))

        try await waitUntil { await setup.fixture.runtime.store.reload().sessions.first { $0.value.id == setup.worker.id }?.value.error != nil }
        let worker = try #require(await setup.fixture.runtime.store.reload().sessions.first { $0.value.id == setup.worker.id }?.value)
        #expect(!worker.state.isLive && worker.error?.contains("worktree was kept") == true)
        #expect(FileManager.default.fileExists(atPath: setup.path + "/late.txt"))
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
