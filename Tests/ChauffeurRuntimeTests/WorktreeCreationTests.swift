import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct WorktreeCreationTests {
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
