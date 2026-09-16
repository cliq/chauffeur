import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct WorktreeCreationTests {
    @Test func previewValidatesBranchesAndMatchesCreationAfterPathCollisions() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        func preview(_ branch: String) async throws -> String {
            let response = try await fixture.runtime.handle(IPCRequest("previewWorktree", params: .object([
                "projectID": .string(fixture.project.id.uuidString),
                "folderID": .string(fixture.project.folders[0].id.uuidString), "branch": .string(branch)
            ])))
            return try #require(response["path"].string)
        }
        for invalid in ["bad branch", "feature/../bad", "main.lock", "@{previous}", "-option", ""] {
            await #expect(throws: ChauffeurError.self) { _ = try await preview(invalid) }
        }
        #expect(await fixture.runtime.store.current().worktrees.isEmpty)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 1)
        var request = fixture.request
        request.branch = WorktreeBranchName.suggested(from: "Fix login flow")
        let original = try await preview(request.branch)
        try FileManager.default.createDirectory(atPath: original, withIntermediateDirectories: true)
        let previewed = try await preview(request.branch)
        #expect(previewed == original + "-2")
        #expect(!FileManager.default.fileExists(atPath: previewed))
        let created = try await fixture.runtime.createWorktree(request)
        #expect(created.value.branch == "fix-login-flow")
        #expect(created.value.path == previewed)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 2)
    }

    @Test func concurrentExternalRegistrationReturnsOneRecord() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let external = fixture.root.appendingPathComponent("external")
        let created = try await ProcessRunner.run("/usr/bin/git", ["-C", fixture.repo.path, "worktree", "add", "-b", "external", external.path, "HEAD"])
        try #require(created.status == 0)
        let params: JSONValue = .object(["projectID": .string(fixture.project.id.uuidString), "folderID": .string(fixture.project.folders[0].id.uuidString), "path": .string(external.path)])
        let registrations = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<12 {
                group.addTask { try await fixture.runtime.handle(IPCRequest("registerWorktree", params: params)).decode(Stored<Worktree>.self).value.id }
            }
            var values: [UUID] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(Set(registrations).count == 1)
        #expect(await fixture.runtime.store.current().worktrees.count == 1)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 2)
    }

    @Test(arguments: [false, true]) func legacyRepositoryIdentityMigratesAfterRelinkingAMovedRepository(registerFirst: Bool) async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let stored = try await fixture.runtime.createWorktree(fixture.request)
        var legacy = stored.value
        legacy.repositoryIdentityVersion = nil
        legacy.repositoryID = try await fixture.runtime.worktrees.legacyRepositoryID(at: fixture.repo.path)
        try JSONCoding.encode(legacy).write(to: URL(fileURLWithPath: stored.path), options: .atomic)
        _ = await fixture.runtime.store.reload()
        let moved = fixture.root.appendingPathComponent("moved repo")
        try FileManager.default.moveItem(at: fixture.repo, to: moved)
        let repaired = try await ProcessRunner.run("/usr/bin/git", ["-C", moved.path, "worktree", "repair"])
        try #require(repaired.status == 0)
        let project = try #require(await fixture.runtime.store.current().projects.first)
        var relinked = project.value
        relinked.folders[0].selectedPath = moved.path; relinked.folders[0].canonicalPath = Paths.canonical(moved.path)
        try await fixture.runtime.store.save(relinked, expectedVersion: project.version)
        if registerFirst {
            let registered = try await fixture.runtime.handle(IPCRequest("registerWorktree", params: .object([
                "projectID": .string(project.value.id.uuidString), "folderID": .string(project.value.folders[0].id.uuidString), "path": .string(legacy.path)
            ]))).decode(Stored<Worktree>.self)
            #expect(registered.value.id == legacy.id)
        }
        await fixture.runtime.reconcileWorktrees()
        let trees = await fixture.runtime.store.current().worktrees
        try #require(trees.count == 1)
        let updated = trees[0].value
        #expect(updated.id == legacy.id && updated.path == legacy.path && updated.baseCommit == legacy.baseCommit && updated.managed)
        #expect(updated.repositoryID == stored.value.repositoryID && updated.repositoryIdentityVersion == 1)
        #expect(updated.repositoryPath == Paths.canonical(moved.path) && updated.availability == .available)
        let reopened = try fixture.reopen(); try await reopened.start()
        #expect(await reopened.store.current().worktrees.first?.value == updated)
        _ = try await reopened.handle(IPCRequest("removeWorktree", params: .object(["worktreeID": .string(updated.id.uuidString)])))
        #expect(!FileManager.default.fileExists(atPath: updated.path))
    }

    @Test(arguments: [false, true]) func legacyRecordWithoutCheckoutIdentityUpgradesAtItsOriginalPathOnly(observeFromLinkedCheckout: Bool) async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let stored = try await fixture.runtime.createWorktree(fixture.request)
        var legacy = stored.value
        legacy.repositoryIdentityVersion = nil; legacy.gitIdentity = nil
        legacy.repositoryID = try await fixture.runtime.worktrees.legacyRepositoryID(at: fixture.repo.path)
        try JSONCoding.encode(legacy).write(to: URL(fileURLWithPath: stored.path), options: .atomic)
        _ = await fixture.runtime.store.reload()
        if observeFromLinkedCheckout {
            let project = try #require(await fixture.runtime.store.current().projects.first)
            var linked = project.value
            linked.folders[0].selectedPath = legacy.path; linked.folders[0].canonicalPath = legacy.path
            try await fixture.runtime.store.save(linked, expectedVersion: project.version)
        }
        await fixture.runtime.reconcileWorktrees()
        let upgraded = try #require(await fixture.runtime.store.current().worktrees.first?.value)
        #expect(upgraded.id == stored.value.id && upgraded.repositoryID == stored.value.repositoryID && upgraded.gitIdentity == stored.value.gitIdentity)
        #expect(upgraded.repositoryIdentityVersion == 1 && upgraded.availability == .available)
        // Once migrated, a repository identity cannot be changed or downgraded.
        var changed = upgraded; changed.repositoryID = UUID()
        await #expect(throws: ChauffeurError.self) { try await fixture.runtime.store.save(changed) }
        changed = upgraded; changed.repositoryIdentityVersion = nil
        await #expect(throws: ChauffeurError.self) { try await fixture.runtime.store.save(changed) }
        var unknown = legacy; unknown.repositoryPath = fixture.root.appendingPathComponent("unknown").path; unknown.path += "-unknown"
        #expect(await fixture.runtime.worktrees.reconciled(unknown, inventory: fixture.runtime.worktrees.observe(at: fixture.repo.path)).availability != .available)
    }

    @Test func retriesShareOneCheckoutAcrossConcurrentCallsAndRuntimeRestart() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        async let first = fixture.runtime.createWorktree(fixture.request)
        async let second = fixture.runtime.createWorktree(fixture.request)
        let (a, b) = try await (first, second)
        #expect(a.value.id == fixture.request.retryKey && a.value == b.value)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 2)
        let reopened = try fixture.reopen()
        try await reopened.start()
        let retry = try await reopened.createWorktree(fixture.request)
        #expect(retry.value.id == a.value.id && retry.value.path == a.value.path)
        var conflicting = fixture.request; conflicting.branch = "another-branch"
        var code: String?
        do { _ = try await reopened.createWorktree(conflicting) } catch let error as ChauffeurError { code = error.code }
        #expect(code == "retry_conflict")
        #expect(try await reopened.worktrees.inventory(at: fixture.repo.path).count == 2)
        // A retry must return the removed record, never recreate its checkout.
        _ = try await reopened.handle(IPCRequest("removeWorktree", params: .object(["worktreeID": .string(a.value.id.uuidString)])))
        #expect(try await reopened.createWorktree(fixture.request).value.registered == false)
        #expect(!FileManager.default.fileExists(atPath: a.value.path))
    }

    @Test func agentFailurePreservesTheCreatedWorktreeAndItsFiles() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let tree = try await fixture.runtime.createWorktree(fixture.request).value
        let marker = URL(fileURLWithPath: tree.path).appendingPathComponent("retained.txt")
        try Data("Keep my changes".utf8).write(to: marker)
        let request = LaunchRequest(projectID: fixture.project.id, groupID: fixture.project.groups[0].id, presetID: fixture.preset.id, folderID: fixture.project.folders[0].id, title: "Failed fixture", worktreeID: tree.id, coordinationEnabled: false)
        await #expect(throws: ChauffeurError.self) { try await fixture.runtime.launch(request) }
        let sessions = try await fixture.runtime.snapshot()["sessions"].decode([Session].self)
        #expect(sessions.count == 1 && sessions[0].state == .failed && sessions[0].worktreeID == tree.id)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "Keep my changes")
        #expect(try await fixture.runtime.createWorktree(fixture.request).value.id == tree.id)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 2)
    }

    @Test func legacyCreateRequestsAndRecordsRemainReadable() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let params: JSONValue = .object(["projectID": .string(fixture.project.id.uuidString), "folderID": .string(fixture.project.folders[0].id.uuidString), "branch": .string("legacy"), "baseRef": .string("HEAD")])
        #expect(try params.decode(WorktreeCreationRequest.self).retryKey == nil)
        let stored = try await fixture.runtime.handle(IPCRequest("createWorktree", params: params)).decode(Stored<Worktree>.self)
        #expect(stored.value.creationRequestFingerprint == nil)
        #expect(try JSONCoding.decode(Worktree.self, from: JSONCoding.encode(stored.value)).id == stored.value.id)
    }

    @Test func deletingAWorktreeRemovesItsCheckoutRecordsAndFinishedHistory() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let folder = fixture.project.folders[0]
        let external = fixture.root.appendingPathComponent("external")
        try #require(try await ProcessRunner.run("/usr/bin/git", ["-C", fixture.repo.path, "worktree", "add", "-b", "external", external.path, "HEAD"]).status == 0)
        let params: JSONValue = .object(["projectID": .string(fixture.project.id.uuidString), "folderID": .string(folder.id.uuidString), "path": .string(external.path)])
        // Launching records the worktree on demand; the missing CLI leaves a failed session behind.
        let registered = try await fixture.runtime.handle(IPCRequest("registerWorktree", params: params)).decode(Stored<Worktree>.self).value
        let launch = LaunchRequest(projectID: fixture.project.id, groupID: fixture.project.groups[0].id, presetID: fixture.preset.id, folderID: folder.id, title: "Doomed", worktreeID: registered.id, coordinationEnabled: false)
        await #expect(throws: ChauffeurError.self) { _ = try await fixture.runtime.launch(launch) }
        var snapshot = await fixture.runtime.store.reload()
        #expect(snapshot.sessions.count == 1 && snapshot.sessions[0].value.state == .failed)
        // Untracked files refuse the deletion and keep everything in place.
        let marker = external.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        var code: String?
        do { _ = try await fixture.runtime.handle(IPCRequest("deleteWorktree", params: params)) } catch let error as ChauffeurError { code = error.code }
        #expect(code == "dirty_worktree")
        snapshot = await fixture.runtime.store.reload()
        #expect(FileManager.default.fileExists(atPath: marker.path) && snapshot.sessions.count == 1 && snapshot.worktrees.count == 1)
        try FileManager.default.removeItem(at: marker)
        let result = try await fixture.runtime.handle(IPCRequest("deleteWorktree", params: params))
        #expect(result["deletedCheckout"].bool == true && result["deletedSessions"].int == 1 && result["deletedRecords"].int == 1)
        snapshot = await fixture.runtime.store.reload()
        #expect(!FileManager.default.fileExists(atPath: external.path))
        #expect(snapshot.sessions.isEmpty && snapshot.worktrees.isEmpty)
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 1)
        #expect(try await fixture.runtime.snapshot()["sessions"].array.isEmpty)
        // The branch survives, as with any git worktree remove.
        #expect(try await ProcessRunner.run("/usr/bin/git", ["-C", fixture.repo.path, "show-ref", "--verify", "refs/heads/external"]).status == 0)
        // The main checkout can never be deleted this way.
        let main: JSONValue = .object(["projectID": .string(fixture.project.id.uuidString), "folderID": .string(folder.id.uuidString), "path": .string(fixture.repo.path)])
        await #expect(throws: ChauffeurError.self) { _ = try await fixture.runtime.handle(IPCRequest("deleteWorktree", params: main)) }
    }

    @Test func vanishedCheckoutsKeepRecordsOnlyWhileSessionsReferToThem() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let folder = fixture.project.folders[0]
        let unused = try await fixture.runtime.createWorktree(fixture.request).value
        var withHistory = fixture.request; withHistory.branch = "task/history"; withHistory.retryKey = UUID()
        let remembered = try await fixture.runtime.createWorktree(withHistory).value
        let launch = LaunchRequest(projectID: fixture.project.id, groupID: fixture.project.groups[0].id, presetID: fixture.preset.id, folderID: folder.id, title: "Doomed", worktreeID: remembered.id, coordinationEnabled: false)
        await #expect(throws: ChauffeurError.self) { _ = try await fixture.runtime.launch(launch) }
        // Both directories disappear behind Chauffeur's back.
        try FileManager.default.removeItem(atPath: unused.path)
        try FileManager.default.removeItem(atPath: remembered.path)
        _ = try await fixture.runtime.handle(IPCRequest("refreshWorktrees"))
        let snapshot = await fixture.runtime.store.reload()
        #expect(snapshot.worktrees.map(\.value.id) == [remembered.id])
        #expect(snapshot.worktrees.first?.value.availability == .missing)
        // Git still lists both as prunable until an explicit prune.
        let stale = try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).filter { $0.prunable }
        #expect(stale.count == 2)
        _ = try await fixture.runtime.handle(IPCRequest("pruneWorktrees", params: .object(["projectID": .string(fixture.project.id.uuidString), "folderID": .string(folder.id.uuidString)])))
        #expect(try await fixture.runtime.worktrees.inventory(at: fixture.repo.path).count == 1)
        // The remembered checkout is gone from Git too, but its history keeps the record.
        let afterPrune = await fixture.runtime.store.reload()
        #expect(afterPrune.worktrees.map(\.value.id) == [remembered.id] && afterPrune.sessions.count == 1)
        // Deleting the finished worktree removes the history and the record.
        let result = try await fixture.runtime.handle(IPCRequest("deleteWorktree", params: .object(["projectID": .string(fixture.project.id.uuidString), "folderID": .string(folder.id.uuidString), "path": .string(remembered.path)])))
        #expect(result["deletedCheckout"].bool == false && result["deletedSessions"].int == 1)
        let final = await fixture.runtime.store.reload()
        #expect(final.worktrees.isEmpty && final.sessions.isEmpty)
    }
}

private struct Fixture {
    let root: URL
    let runtime: RuntimeCoordinator
    let project: Project
    let preset: AgentPreset
    let request: WorktreeCreationRequest
    var repo: URL { root.appendingPathComponent("repo 日本語") }
    static func make() async throws -> Self {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-create-\(UUID())").resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo 日本語")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "core.hooksPath", "/dev/null"], ["config", "commit.gpgsign", "false"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"]] {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path] + args)
            guard result.status == 0 else { throw ChauffeurError("fixture_git", result.error) }
        }
        let runtime = try RuntimeCoordinator(root: root, ctlPath: "/bin/false", environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": root.path])
        let set = PresetSet(name: "Worktree fixture")
        let preset = AgentPreset(setID: set.id, name: "Unavailable agent", kind: .claude, executable: root.appendingPathComponent("missing-cli").path, configurationDirectory: root.path)
        var project = Project(name: "Worktree fixture", presetSetID: set.id)
        project.addFolder(ProjectFolder(path: repo.path))
        try await runtime.store.save(set); try await runtime.store.save(preset); try await runtime.store.save(project)
        try await runtime.start()
        return Self(root: root, runtime: runtime, project: project, preset: preset, request: WorktreeCreationRequest(projectID: project.id, folderID: project.folders[0].id, branch: "task/fixture", baseRef: "HEAD"))
    }
    func reopen() throws -> RuntimeCoordinator {
        try RuntimeCoordinator(root: root, ctlPath: "/bin/false", environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": root.path])
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
