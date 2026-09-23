import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct GitRefReaderTests {
    @Test func metadataTracksUpstreamDivergenceAndRemoteBasesDoNotCreateTrackingBranches() async throws {
        let fixture = try await RefFixture.make()
        defer { fixture.cleanup() }
        try await fixture.git(["config", "remote.origin.url", fixture.repo.path])
        try await fixture.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        try await fixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try await fixture.git(["branch", "--set-upstream-to=origin/main", "main"])
        try await fixture.git(["commit", "--allow-empty", "-m", "Ahead"])
        let snapshot = try await GitRefReader().list(at: fixture.repo.path)
        let main = try #require(snapshot.refs.first { $0.fullName == "refs/heads/main" })
        #expect(main.ahead == 1 && main.behind == 0)
        let remote = try #require(snapshot.refs.first { $0.kind == .remote })
        let manager = WorktreeManager(root: fixture.root.appendingPathComponent("managed"))
        let tree = try await manager.create(projectID: UUID(), folder: ProjectFolder(path: fixture.repo.path), branch: "task/from-remote", baseRef: remote.fullName)
        #expect(tree.baseCommit == remote.sha)
        let config = try await ProcessRunner.run("/usr/bin/git", ["-C", fixture.repo.path, "config", "--get", "branch.task/from-remote.remote"])
        #expect(config.status == 1)
        let updated = try await GitRefReader().list(at: fixture.repo.path)
        #expect(updated.refs.first { $0.name == "task/from-remote" }?.isCheckedOutInWorktree == true)
    }

    @Test func listsRefsWithoutSymbolicRemoteDuplicatesAndKeepsKindsUnambiguous() async throws {
        let fixture = try await RefFixture.make()
        defer { fixture.cleanup() }
        try await fixture.git(["branch", "feature/nested/task"])
        try await fixture.git(["tag", "main"])
        try await fixture.git(["tag", "-a", "v1", "-m", "Release"])
        try await fixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        try await fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        try await fixture.git(["config", "remote.origin.url", fixture.repo.path])
        try await fixture.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        try await fixture.git(["branch", "--set-upstream-to=origin/main", "main"])
        let snapshot = try await GitRefReader().list(at: fixture.repo.path)
        #expect(snapshot.refs.count == 5)
        #expect(!snapshot.refs.contains { $0.name == "origin/HEAD" })
        let main = try #require(snapshot.refs.first { $0.fullName == "refs/heads/main" })
        #expect(main.isHEAD && main.isCheckedOutInWorktree && main.isMerged)
        #expect(main.upstream == "refs/remotes/origin/main")
        #expect(snapshot.defaultBranch == "refs/heads/main")
        #expect(snapshot.head?.subject == "Initial")
        #expect(snapshot.refs.first { $0.name == "v1" }?.sha == main.sha)
        #expect(snapshot.refs.filter { $0.name == "main" }.count == 2)
        #expect(snapshot.fetchedAt == nil)
    }

    @Test func resolvesOnlyHexCommitsIncludingAbbreviations() async throws {
        let fixture = try await RefFixture.make()
        defer { fixture.cleanup() }
        let reader = GitRefReader()
        let sha = try await fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try await reader.resolve(String(sha.prefix(8)), at: fixture.repo.path)
        #expect(commit?.sha == sha)
        #expect(commit?.subject == "Initial")
        #expect(try await reader.resolve("deadbeefdeadbeef", at: fixture.repo.path) == nil)
        for invalid in ["HEAD", "--help", "abc", "abcd;echo", String(repeating: "a", count: 41)] {
            await #expect(throws: ChauffeurError.self) { _ = try await reader.resolve(invalid, at: fixture.repo.path) }
        }
    }

    @Test func unbornRepositoryHasNoInventedHeadAndBrokenRepositoryThrows() async throws {
        let fixture = try await RefFixture.make(commit: false)
        defer { fixture.cleanup() }
        let reader = GitRefReader()
        let snapshot = try await reader.list(at: fixture.repo.path)
        #expect(snapshot.refs.isEmpty && snapshot.head == nil)
        await #expect(throws: ChauffeurError.self) { _ = try await reader.list(at: fixture.root.path) }
    }
}

private struct RefFixture {
    let root: URL
    var repo: URL { root.appendingPathComponent("repo") }
    static func make(commit: Bool = true) async throws -> Self {
        let fixture = Self(root: FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-refs-\(UUID())"))
        try FileManager.default.createDirectory(at: fixture.repo, withIntermediateDirectories: true)
        try await fixture.git(["init", "-b", "main"])
        try await fixture.git(["config", "user.name", "Fixture"])
        try await fixture.git(["config", "user.email", "fixture@example.invalid"])
        if commit { try await fixture.git(["commit", "--allow-empty", "-m", "Initial"]) }
        return fixture
    }
    @discardableResult func git(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/git", ["-C", repo.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + arguments)
        try #require(result.status == 0, "Git fixture failed: \(result.error)")
        return result.output
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
