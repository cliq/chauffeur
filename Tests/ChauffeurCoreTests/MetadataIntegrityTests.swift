import Foundation
import Testing
@testable import ChauffeurCore

struct MetadataIntegrityTests {
    @Test func childRecordsMustMatchTheirContainingSetAndProject() async throws {
        let fixture = try await MetadataFixture.make(); defer { fixture.cleanup() }
        let session = try await fixture.store.save(fixture.session())
        let tree = try await fixture.store.save(fixture.worktree())
        let window = try await fixture.store.save(WindowState(projectID: fixture.project.value.id))
        var foreignPreset = fixture.preset.value; foreignPreset.setID = UUID()
        var foreignSession = session.value; foreignSession.projectID = UUID()
        var foreignTree = tree.value; foreignTree.projectID = UUID()
        var foreignWindow = window.value; foreignWindow.id = UUID()
        try JSONCoding.encode(foreignPreset).write(to: URL(fileURLWithPath: fixture.preset.path))
        try JSONCoding.encode(foreignSession).write(to: URL(fileURLWithPath: session.path))
        try JSONCoding.encode(foreignTree).write(to: URL(fileURLWithPath: tree.path))
        try JSONCoding.encode(foreignWindow).write(to: URL(fileURLWithPath: window.path))
        let snapshot = await fixture.store.reload()
        #expect(snapshot.presets.isEmpty && snapshot.sessions.isEmpty && snapshot.worktrees.isEmpty && snapshot.windows.isEmpty)
        for path in [fixture.preset.path, session.path, tree.path, window.path] {
            #expect(snapshot.errors.contains { $0.path == path && $0.code == "invalid_record" })
            #expect(FileManager.default.fileExists(atPath: path))
        }
        #expect(snapshot.projects.count == 1 && snapshot.presetSets.count == 1)
    }

    @Test func brokenReferencesAreReportedWithoutRewritingHistory() async throws {
        let fixture = try await MetadataFixture.make(); defer { fixture.cleanup() }
        let tree = try await fixture.store.save(fixture.worktree())
        var sessionValue = fixture.session(); sessionValue.worktreeID = tree.value.id
        let session = try await fixture.store.save(sessionValue)
        var windowValue = WindowState(projectID: fixture.project.value.id)
        windowValue.tabs = [session.value.id]; windowValue.selectedSessionID = session.value.id
        let window = try await fixture.store.save(windowValue)
        let original = try Data(contentsOf: URL(fileURLWithPath: session.path))
        var project = fixture.project.value
        project.groups = [AgentGroup(name: "Replacement", isDefault: true)]
        project.folders = []; project.presetSetID = UUID(); project.lastPresetID = UUID()
        try JSONCoding.encode(project).write(to: URL(fileURLWithPath: fixture.project.path))
        var brokenWindow = window.value; brokenWindow.tabs = [UUID()]; brokenWindow.selectedSessionID = brokenWindow.tabs[0]
        try JSONCoding.encode(brokenWindow).write(to: URL(fileURLWithPath: window.path))
        let snapshot = await fixture.store.reload()
        #expect(snapshot.sessions.count == 1 && snapshot.worktrees.count == 1 && snapshot.projects.count == 1)
        for path in [fixture.project.path, tree.path, session.path, window.path] { #expect(snapshot.errors.contains { $0.path == path }) }
        #expect(snapshot.errors.contains { $0.code == "unresolved_preset_set" })
        #expect(try Data(contentsOf: URL(fileURLWithPath: session.path)) == original)
    }

    @Test func writesRejectForeignReferencesAndPreserveArchivedTargets() async throws {
        let fixture = try await MetadataFixture.make(); defer { fixture.cleanup() }
        var set = try #require(await fixture.store.current().presetSets.first)
        var badDefault = set.value; badDefault.defaultPresetID = UUID()
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(badDefault, expectedVersion: set.version) }
        var foreign = fixture.preset.value; foreign.setID = try await fixture.store.save(PresetSet(name: "Other")).value.id
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(foreign, expectedVersion: fixture.preset.version) }
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(Project(name: "No set", presetSetID: UUID())) }
        var badSession = fixture.session(); badSession.groupID = UUID()
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(badSession) }
        var badTree = fixture.worktree(); badTree.folderID = UUID()
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(badTree) }

        var project = fixture.project.value
        let group = AgentGroup(name: "Historical"); project.groups.append(group)
        let updated = try await fixture.store.save(project, expectedVersion: fixture.project.version)
        var sessionValue = fixture.session(); sessionValue.groupID = group.id
        let session = try await fixture.store.save(sessionValue)
        var removed = project; removed.groups.removeAll { $0.id == group.id }
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(removed, expectedVersion: updated.version) }
        removed = project; removed.folders = []
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(removed, expectedVersion: updated.version) }
        project.groups[1].archived = true; project.folders[0].registered = false
        try await fixture.store.save(project, expectedVersion: updated.version)
        var archived = fixture.preset.value; archived.archived = true
        try await fixture.store.save(archived, expectedVersion: fixture.preset.version)
        set = try #require(await fixture.store.current().presetSets.first { $0.value.id == fixture.set.id })
        var defaultSet = set.value; defaultSet.defaultPresetID = archived.id
        try await fixture.store.save(defaultSet, expectedVersion: set.version)
        let snapshot = await fixture.store.reload()
        #expect(snapshot.errors.isEmpty)
        #expect(try JSONCoding.encode(snapshot.sessions.first?.value.launch) == JSONCoding.encode(session.value.launch))
    }

    @Test func presetChangesAdvanceParentRevisionAndRejectStaleWriters() async throws {
        let fixture = try await MetadataFixture.make(); defer { fixture.cleanup() }
        let initial = try #require(await fixture.store.current().presetSets.first)
        #expect(initial.value.revision == fixture.set.revision + 1)
        var changed = fixture.preset.value; changed.arguments = ["--model", "fixture-model"]
        let saved = try await fixture.store.save(changed, expectedVersion: fixture.preset.version)
        #expect(await fixture.store.current().presetSets.first?.value.revision == initial.value.revision + 1)
        try await fixture.store.save(saved.value, expectedVersion: saved.version)
        #expect(await fixture.store.current().presetSets.first?.value.revision == initial.value.revision + 1)
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(fixture.preset.value, expectedVersion: fixture.preset.version) }
        #expect(await fixture.store.current().presetSets.first?.value.revision == initial.value.revision + 1)
        var staleSet = initial.value; staleSet.name = "Stale rename"
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(staleSet, expectedVersion: initial.version) }
        let current = try #require(await fixture.store.current().presetSets.first)
        var renamed = current.value; renamed.name = "Renamed"; renamed.revision = 999
        let result = try await fixture.store.save(renamed, expectedVersion: current.version)
        #expect(result.value.revision == current.value.revision + 1)
        #expect(result.path == current.path)
    }

    @Test func rememberedPresetSurvivesReopenAndDoesNotOverwriteProjectEditsOrSetChanges() async throws {
        let fixture = try await MetadataFixture.make(); defer { fixture.cleanup() }
        var external = fixture.project.value; external.name = "Edited outside Chauffeur"
        try JSONCoding.encode(external).write(to: URL(fileURLWithPath: fixture.project.path))
        try await fixture.store.rememberPreset(fixture.preset.value.id, projectID: external.id, setID: fixture.set.id)
        let reopened = try FileStore(root: fixture.root)
        let remembered = try #require(await reopened.reload().projects.first)
        #expect(remembered.value.name == external.name && remembered.value.lastPresetID == fixture.preset.value.id)
        await #expect(throws: ChauffeurError.self) { try await fixture.store.save(fixture.project.value, expectedVersion: fixture.project.version) }
        let other = try await fixture.store.save(PresetSet(name: "New set"))
        var switched = remembered.value; switched.presetSetID = other.value.id
        try await fixture.store.save(switched, expectedVersion: remembered.version)
        try await fixture.store.rememberPreset(fixture.preset.value.id, projectID: external.id, setID: fixture.set.id)
        let final = try #require(await reopened.reload().projects.first)
        #expect(final.value.presetSetID == other.value.id && final.value.lastPresetID == nil)
    }

    @Test func symlinkedChildDirectoriesAreNotLoaded() async throws {
        let fixture = try await MetadataFixture.make(); defer { fixture.cleanup() }
        let parent = URL(fileURLWithPath: fixture.preset.path).deletingLastPathComponent()
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: parent, to: outside)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        let snapshot = await fixture.store.reload()
        #expect(snapshot.presets.isEmpty)
        #expect(snapshot.errors.contains { $0.path == parent.path })
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent(URL(fileURLWithPath: fixture.preset.path).lastPathComponent).path))
    }
}

private struct MetadataFixture {
    let root: URL
    let store: FileStore
    let set: PresetSet
    let preset: Stored<AgentPreset>
    let project: Stored<Project>
    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-metadata-\(UUID())")
        let store = try FileStore(root: root)
        let set = PresetSet(name: "Fixture")
        try await store.save(set)
        let preset = try await store.save(AgentPreset(setID: set.id, name: "Fixture", kind: .claude, executable: "/bin/cat", configurationDirectory: root.path))
        var project = Project(name: "Fixture", presetSetID: set.id)
        project.addFolder(ProjectFolder(path: root.path))
        return Self(root: root, store: store, set: set, preset: preset, project: try await store.save(project))
    }
    func session() -> Session {
        Session(projectID: project.value.id, groupID: project.value.groups[0].id, title: "Historical fixture", launch: LaunchSnapshot(preset: preset.value, set: set, executablePath: "/bin/cat", executableVersion: "fixture", workingDirectory: root.path, additionalPaths: []), folderID: project.value.folders[0].id)
    }
    func worktree() -> Worktree {
        Worktree(projectID: project.value.id, folderID: project.value.folders[0].id, repositoryID: UUID(), path: root.appendingPathComponent("checkout").path, repositoryPath: root.path, branch: "fixture", baseCommit: "fixture", managed: false)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
