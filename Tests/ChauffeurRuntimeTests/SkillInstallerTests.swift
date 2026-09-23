import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct SkillInstallerTests {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-skill-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func linksShareUpdatedCatalogIncludingReferencesAndRepairMissingLinks() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try CoordinationSkill.bundledCatalog()
        let source = root.appendingPathComponent("source")
        let installer = try SkillInstaller(skills: catalog, root: source)
        let profiles = [root.appendingPathComponent(".agents").path, root.appendingPathComponent("claude").path]
        try await installer.publish()
        #expect(await installer.reconcile(directories: profiles + profiles).count == profiles.count * catalog.count)
        let progress = try #require(catalog.first { $0.name == CoordinationSkill.progressName })
        for profile in profiles {
            for (path, expected) in progress.referenceFiles {
                let installed = URL(fileURLWithPath: profile).appendingPathComponent("skills/implementation-progress/" + path)
                #expect(try Data(contentsOf: installed) == expected)
            }
        }
        let link = root.appendingPathComponent(".agents/skills/chauffeur-orchestrator")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(destination == source.appendingPathComponent("current/chauffeur-orchestrator").path)
        let reference = link.appendingPathComponent("references/roles/worker.md")
        #expect(try Data(contentsOf: reference) == catalog[1].referenceFiles["references/roles/worker.md"])
        let updated = try catalog.map { skill in
            try CoordinationSkill(name: skill.name, displayName: skill.displayName, summary: skill.summary,
                version: skill.version, dependencies: skill.dependencies,
                document: skill.document + Data("\nUpdated guidance\n".utf8),
                referenceFiles: skill.referenceFiles.mapValues { $0 + Data("\nUpdated role\n".utf8) })
        }
        let next = try SkillInstaller(skills: updated, root: source)
        try await next.publish()
        try await next.publish() // Idempotent source validation includes all references.
        #expect(try String(contentsOf: reference, encoding: .utf8).contains("Updated role"))
        let updatedScript = root.appendingPathComponent(".agents/skills/implementation-progress/scripts/progress.py")
        #expect(try String(contentsOf: updatedScript, encoding: .utf8).contains("Updated role"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == destination)
        #expect(await next.statuses(directory: profiles[0]).allSatisfy { $0.state == .installed })
        try FileManager.default.removeItem(at: link)
        #expect(await next.reconcile(directories: profiles).allSatisfy { $0.state == .installed })
    }

    @Test(arguments: ["directory", "file", "link", "broken-link"])
    func conflictingTargetsArePreserved(kind: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = try SkillInstaller(skills: CoordinationSkill.bundledCatalog(), root: root.appendingPathComponent("source"))
        try await installer.publish()
        let profile = root.appendingPathComponent("profile")
        let skills = profile.appendingPathComponent("skills")
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        let target = skills.appendingPathComponent("chauffeur")
        let external = root.appendingPathComponent("external")
        try Data("keep".utf8).write(to: external)
        switch kind {
        case "directory": try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        case "file": try Data("keep".utf8).write(to: target)
        default: try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: kind == "link" ? external.path : root.appendingPathComponent("missing").path)
        }
        let result = await installer.reconcile(directories: [profile.path])
        #expect(result.first { $0.name == "chauffeur" }?.state == .conflict)
        #expect(result.first { $0.name == "chauffeur-orchestrator" }?.state == .installed)
        #expect(try String(contentsOf: external, encoding: .utf8) == "keep")
        if kind == "file" { #expect(try String(contentsOf: target, encoding: .utf8) == "keep") }
        if kind.contains("link") { #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil) }
    }

    @Test func editedManagedSourceIsReportedWithoutOverwritingIt() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = try SkillInstaller(skills: CoordinationSkill.bundledCatalog(), root: root.appendingPathComponent("source"))
        try await installer.publish()
        let profile = root.appendingPathComponent("profile").path
        _ = await installer.reconcile(directories: [profile])
        let document = root.appendingPathComponent("source/current/chauffeur/SKILL.md")
        try Data("user changes".utf8).write(to: document)
        await #expect(throws: ChauffeurError.self) { try await installer.publish() }
        #expect(await installer.statuses(directory: profile).allSatisfy { $0.state == .conflict })
        #expect(try String(contentsOf: document, encoding: .utf8) == "user changes")
    }

    @Test func defaultsAndSharedTeamDirectoriesAreDeduplicated() throws {
        var first = PresetSet(name: "First")
        first.configurationDirectories = ["claude": "/tmp/shared-claude"]
        var second = PresetSet(name: "Second")
        second.configurationDirectories = first.configurationDirectories
        var archived = PresetSet(name: "Archived"); archived.archived = true
        archived.configurationDirectories = ["claude": "/tmp/archived-claude"]
        #expect(SkillInstaller.directories(teams: [first, second, PresetSet(name: "Default"), archived], home: "/tmp/home") ==
            ["/tmp/home/.agents", "/tmp/home/.claude", "/tmp/shared-claude"].map(Paths.canonical).sorted())
    }

    @Test func runtimeInstallsAtStartupAndWhenTeamDirectoryChanges() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let runtime = try RuntimeCoordinator(root: root.appendingPathComponent("data"), ctlPath: "/bin/false",
            environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": home.path])
        try await runtime.start()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".agents/skills/chauffeur").path)) != nil)
        var team = PresetSet(name: "New")
        team.configurationDirectories = ["claude": root.appendingPathComponent("claude-one").path]
        team.agentSelection = .allBase
        let saved = try await runtime.handle(IPCRequest("savePresetSet", params: .object(["record": try .from(team)]))).decode(Stored<PresetSet>.self)
        let first = root.appendingPathComponent("claude-one/skills/chauffeur")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: first.path)) != nil)
        team = saved.value
        team.configurationDirectories = ["claude": root.appendingPathComponent("claude-two").path]
        _ = try await runtime.handle(IPCRequest("savePresetSet", params: .object(["record": try .from(team), "version": .string(saved.version)])))
        let second = root.appendingPathComponent("claude-two/skills/chauffeur-orchestrator")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: second.path)) != nil)
        #expect(FileManager.default.fileExists(atPath: first.path)) // Changing teams does not remove another user's discovery path.
    }
}
