import Foundation
import Darwin
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct SkillInstallerTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-skill-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func mode(_ path: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int)
    }

    @Test func installUpgradeRemovePreservesTheRestOfAProfile() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let skill = try CoordinationSkill.bundled()
        let old = try CoordinationSkill(version: "0.9.0", document: Data(String(decoding: skill.document, as: UTF8.self).replacingOccurrences(of: "version: \"1.0.0\"", with: "version: \"0.9.0\"").utf8))
        let previous = SkillInstaller(skill: old), current = SkillInstaller(skill: skill)
        let sentinel = root.appendingPathComponent("settings.json")
        let sentinelData = Data("untouched fixture settings".utf8)
        try sentinelData.write(to: sentinel)
        let before = await previous.status(directory: root.path)
        #expect(before.state == .notInstalled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["settings.json"])
        let installed = try await previous.install(directory: root.path, revision: before.revision)
        #expect(installed.state == .installed && installed.installedVersion == "0.9.0")
        let target = root.appendingPathComponent("skills/chauffeur")
        #expect(try mode(target) == 0o700 && mode(target.appendingPathComponent("SKILL.md")) == 0o600)
        let upgrade = await current.status(directory: root.path)
        #expect(upgrade.state == .updateAvailable)
        let updated = try await current.install(directory: root.path, revision: upgrade.revision)
        #expect(updated.installedVersion == skill.version && updated.state == .installed)
        #expect(try Data(contentsOf: target.appendingPathComponent("SKILL.md")) == skill.document)
        // A stale sheet must not remove or install into changed state.
        await #expect(throws: ChauffeurError.self) { try await current.remove(directory: root.path, revision: upgrade.revision) }
        let removed = try await current.remove(directory: root.path, revision: updated.revision)
        #expect(removed.state == .notInstalled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("skills").path).isEmpty)
        #expect(try Data(contentsOf: sentinel) == sentinelData)
        #expect(try mode(root.appendingPathComponent(".chauffeur-skill.lock")) == 0o600)
        #expect(try Data(contentsOf: root.appendingPathComponent(".chauffeur-skill.lock")).isEmpty)
        let other = root.appendingPathComponent("other"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        await #expect(throws: ChauffeurError.self) { try await current.install(directory: other.path, revision: removed.revision) }
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("skills/chauffeur").path))
    }

    @Test(arguments: ["document", "receipt", "extra", "foreign", "symlink-file", "hardlink-file", "symlink-target", "symlink-skills"])
    func editedAndUnmanagedFilesAreNeverRemoved(kind: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = SkillInstaller(skill: try CoordinationSkill.bundled())
        let before = await installer.status(directory: root.path)
        let installed = try await installer.install(directory: root.path, revision: before.revision)
        let target = root.appendingPathComponent("skills/chauffeur"), file = target.appendingPathComponent("SKILL.md")
        let external = root.appendingPathComponent("external.txt")
        let marker = Data("preserve user content".utf8); try marker.write(to: external)
        switch kind {
        case "document": try marker.write(to: file)
        case "receipt": try Data("{}".utf8).write(to: target.appendingPathComponent(".chauffeur-install.json"))
        case "extra": try marker.write(to: target.appendingPathComponent("notes.txt"))
        case "foreign": try FileManager.default.removeItem(at: target.appendingPathComponent(".chauffeur-install.json"))
        case "symlink-file", "hardlink-file":
            try FileManager.default.removeItem(at: file)
            if kind == "symlink-file" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external) }
            else { try FileManager.default.linkItem(at: external, to: file) }
        case "symlink-target", "symlink-skills":
            let original = kind == "symlink-target" ? target : target.deletingLastPathComponent()
            let moved = root.appendingPathComponent("saved")
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        default: Issue.record("Unknown fixture")
        }
        let changed = await installer.status(directory: root.path)
        #expect(changed.state == .conflict)
        await #expect(throws: ChauffeurError.self) { try await installer.remove(directory: root.path, revision: installed.revision) }
        await #expect(throws: ChauffeurError.self) { try await installer.remove(directory: root.path, revision: changed.revision) }
        await #expect(throws: ChauffeurError.self) { try await installer.install(directory: root.path, revision: changed.revision) }
        #expect(try Data(contentsOf: external) == marker)
        #expect(FileManager.default.fileExists(atPath: target.path))
        if kind == "document" { #expect(try Data(contentsOf: file) == marker) }
        if kind == "extra" { #expect(try Data(contentsOf: target.appendingPathComponent("notes.txt")) == marker) }
    }

    @Test func missingProfilesAndConcurrentProfileWritersFailWithoutOverwriting() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let installer = SkillInstaller(skill: try CoordinationSkill.bundled())
        let missing = root.appendingPathComponent("missing")
        let absent = await installer.status(directory: missing.path)
        #expect(absent.state == .unavailable)
        await #expect(throws: ChauffeurError.self) { try await installer.install(directory: missing.path, revision: absent.revision) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let before = await installer.status(directory: root.path)
        let lock = open(root.appendingPathComponent(".chauffeur-skill.lock").path, O_RDWR | O_CREAT, 0o600)
        #expect(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { flock(lock, LOCK_UN); close(lock) }
        do { _ = try await installer.install(directory: root.path, revision: before.revision); Issue.record("Concurrent writer ignored") }
        catch let error as ChauffeurError { #expect(error.code == "skill_busy") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("skills").path))
    }
}
