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
            #expect(FolderRoute(url: URL(string: value.replacingOccurrences(of: "chauffeur:", with: AppBuild.current.urlScheme + ":"))!) == nil)
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
        #expect(TerminalLauncherInstallation.isInstalled(executable: source, at: destination))
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

    @Test func installedCommandPreservesArgumentsAndCanBeRepairedAfterAppMove() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("App '日本語 $()"), moved = root.appendingPathComponent("Moved app")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let source = original.appendingPathComponent("chauffeur-launcher"), destination = root.appendingPathComponent("bin/chauffeur")
        try Data("#!/bin/sh\nprintf '%s\\000' \"$@\"\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        try TerminalLauncherInstallation.install(executable: source, at: destination)
        let arguments = ["", "--", "space 日本語", "\"' $() `literal`", "line\nbreak"]
        func output() throws -> Data {
            let process = Process(), pipe = Pipe()
            process.executableURL = destination; process.arguments = arguments; process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return data
        }
        let expected = Data((arguments.joined(separator: "\0") + "\0").utf8)
        #expect(try output() == expected)
        try FileManager.default.moveItem(at: original, to: moved)
        let newSource = moved.appendingPathComponent("chauffeur-launcher")
        #expect(!TerminalLauncherInstallation.isInstalled(executable: newSource, at: destination))
        try TerminalLauncherInstallation.install(executable: newSource, at: destination)
        #expect(TerminalLauncherInstallation.isInstalled(executable: newSource, at: destination))
        #expect(try output() == expected)
    }

    @Test func installationUpgradesAnExistingAppLinkWithoutLeavingTemporaryFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let oldApp = root.appendingPathComponent("Previous.app")
        let oldSource = oldApp.appendingPathComponent("Contents/MacOS/chauffeur-launcher")
        let source = root.appendingPathComponent("new-launcher"), destination = root.appendingPathComponent("chauffeur")
        try FileManager.default.createDirectory(at: oldSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.chauffeur.app", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try plist.write(to: oldApp.appendingPathComponent("Contents/Info.plist"))
        for path in [oldSource, source] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: oldSource)
        try TerminalLauncherInstallation.install(executable: source, at: destination)
        #expect(TerminalLauncherInstallation.isInstalled(executable: source, at: destination))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".chauffeur-") })
    }
}
