import Foundation
import Testing
@testable import ChauffeurCore

struct FolderLauncherTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-launcher-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func folderURLsRoundTripLiteralPathsAndRejectExtraFields() throws {
        for path in ["/", "/work/client space/日本語", "/work/a&b?#%+", "/work/quote'\"\nline", "/work/$(not-a-command)"] {
            #expect(FolderRoute(url: FolderRoute(path: path).url)?.path == path)
        }
        for value in ["https://open?path=/x", "chauffeur://open/x?path=/x", "chauffeur://user@open?path=/x", "chauffeur://open:80?path=/x", "chauffeur://open?path=/x#fragment", "chauffeur://open?path=relative", "chauffeur://open?path=/x&path=/y", "chauffeur://open?path=/x&command=run", "chauffeur://open?path=%00", "chauffeur://open"] {
            #expect(FolderRoute(url: URL(string: value)!) == nil)
        }
    }
    @Test func closestAncestorAndSharedProjectsAreResolvedWithoutPrefixCollisions() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo"), nested = repo.appendingPathComponent("nested"), sub = nested.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sub)
        var parent = Project(name: "Parent", presetSetID: UUID()); parent.addFolder(ProjectFolder(path: repo.path))
        var child = Project(name: "Child", presetSetID: UUID()); child.addFolder(ProjectFolder(path: nested.path))
        var shared = Project(name: "Shared", presetSetID: UUID()); shared.addFolder(ProjectFolder(path: nested.path))
        #expect(ProjectFolderResolver.matches(path: alias.path, projects: [parent, child], worktrees: []).map(\.projectID) == [child.id])
        #expect(Set(ProjectFolderResolver.matches(path: sub.path, projects: [shared, parent, child], worktrees: []).map(\.projectID)) == [shared.id, child.id])
        #expect(ProjectFolderResolver.matches(path: repo.path + "-other", projects: [parent], worktrees: []).isEmpty)
        child.folders[0].registered = false
        #expect(ProjectFolderResolver.matches(path: sub.path, projects: [parent, child], worktrees: []).map(\.projectID) == [parent.id])
        parent.archived = true
        #expect(ProjectFolderResolver.matches(path: repo.path, projects: [parent], worktrees: []).map(\.projectID) == [parent.id])
    }
    @Test func registeredAndDiscoveredWorktreesResolveToTheirRepositoryProject() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo"), checkout = root.appendingPathComponent("outside checkout"), external = root.appendingPathComponent("external")
        for path in [repo, checkout, external] { try FileManager.default.createDirectory(at: path.appendingPathComponent("Sources"), withIntermediateDirectories: true) }
        var project = Project(name: "Project", presetSetID: UUID()); project.addFolder(ProjectFolder(path: repo.path))
        var tree = Worktree(projectID: project.id, folderID: project.folders[0].id, repositoryID: UUID(), path: checkout.path, repositoryPath: repo.path, branch: "feature", baseCommit: "fixture", managed: true)
        #expect(ProjectFolderResolver.matches(path: checkout.appendingPathComponent("Sources").path, projects: [project], worktrees: [tree]).first?.folderID == project.folders[0].id)
        tree.registered = false
        #expect(ProjectFolderResolver.matches(path: checkout.path, projects: [project], worktrees: [tree]).isEmpty)
        var inventory = RepositoryInventory(sourcePath: project.folders[0].canonicalPath, status: .available)
        inventory.entries = [GitWorktree(path: external.path, commit: "fixture", branch: "external", locked: false, prunable: false)]
        #expect(ProjectFolderResolver.matches(path: external.appendingPathComponent("Sources").path, projects: [project], worktrees: [], inventories: [inventory]).first?.projectID == project.id)
        inventory.entries[0].availability = .missing
        #expect(ProjectFolderResolver.matches(path: external.path, projects: [project], worktrees: [], inventories: [inventory]).isEmpty)
    }
    @Test func installationIsIdempotentAndPreservesUnrelatedCommands() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source/chauffeur"), destination = root.appendingPathComponent("bin/chauffeur")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try TerminalLauncherInstallation.install(executable: source, at: destination)
        try TerminalLauncherInstallation.install(executable: source, at: destination)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == source.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: destination)
        try Data("keep me".utf8).write(to: destination)
        #expect(throws: ChauffeurError.self) { try TerminalLauncherInstallation.install(executable: source, at: destination) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep me")
        try FileManager.default.removeItem(at: destination)
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: foreign)
        #expect(throws: ChauffeurError.self) { try TerminalLauncherInstallation.install(executable: source, at: destination) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == foreign.path)
    }
}
