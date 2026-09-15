import Foundation
import Testing
@testable import ChauffeurCore

struct MetadataWatcherTests {
    @Test func fileEventsReloadOneRecordAndIdleSnapshotsDoNotReadDisk() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        var records: [Stored<PresetSet>] = []
        for index in 0..<12 { records.append(try await store.save(PresetSet(name: "Set \(index)"))) }
        _ = await store.reload(); try await quiet(store)
        let before = await store.ioCounts()
        for _ in 0..<20 { _ = await store.refresh() }
        #expect(await store.ioCounts() == before)

        // Runtime databases, captures and managed Git files are outside metadata.
        try Data("ignored".utf8).write(to: root.appendingPathComponent("runtime/noise"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("worktrees/noise"))
        try await Task.sleep(for: .milliseconds(800)); try await quiet(store)
        #expect(await store.ioCounts() == before)

        let changed = records[4]
        var value = changed.value; value.name = "Edited with an external atomic save"
        try JSONCoding.encode(value).write(to: URL(fileURLWithPath: changed.path), options: .atomic)
        try await wait { await store.refresh().presetSets.contains { $0.value.name == value.name } }
        try await quiet(store)
        let after = await store.ioCounts()
        // One atomic replacement can deliver multiple FSEvents batches. Verify
        // which records were read, independently of that OS delivery timing.
        let reread = Set(after.recordsByPath.keys.filter { after.recordsByPath[$0] != before.recordsByPath[$0] })
        #expect(reread == [changed.path], "Only the changed file should be reread")
        let cached = await store.current()
        #expect(cached.presetSets.count == 12 && cached.errors.isEmpty)
        #expect(cached.presetSets.first { $0.value.id == changed.value.id }?.version != changed.version)
    }

    @Test func eventsRecoverCorruptionAndDirectoryRenamesAndReplacement() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        let set = try await store.save(PresetSet(name: "Original"))
        let project = try await store.save(Project(name: "Original", presetSetID: set.value.id))
        _ = await store.reload(); try await quiet(store)
        let setURL = URL(fileURLWithPath: set.path)
        try Data("{ invalid private-content".utf8).write(to: setURL, options: .atomic)
        try await wait {
            let snapshot = await store.refresh()
            return snapshot.presetSets.isEmpty && snapshot.errors.contains { $0.path == set.path }
        }
        #expect(await store.current().errors.allSatisfy { !$0.message.contains("private-content") })
        try JSONCoding.encode(set.value).write(to: setURL, options: .atomic)
        try await wait { await store.refresh().presetSets.count == 1 }
        #expect(await store.current().errors.isEmpty)

        let oldDirectory = URL(fileURLWithPath: project.path).deletingLastPathComponent()
        let renamed = oldDirectory.deletingLastPathComponent().appendingPathComponent("renamed in Finder")
        try FileManager.default.moveItem(at: oldDirectory, to: renamed)
        try await wait { await store.refresh().projects.first?.path == renamed.appendingPathComponent("project.json").path }
        let projects = root.appendingPathComponent("projects")
        let backup = root.appendingPathComponent("projects-backup")
        try FileManager.default.moveItem(at: projects, to: backup)
        try await wait { await store.refresh().projects.isEmpty }
        try FileManager.default.moveItem(at: backup, to: projects)
        try await wait { await store.refresh().projects.first?.value.id == project.value.id }
        #expect(await store.current().errors.isEmpty)

        // Copy in a whole project directory while the service is already watching.
        let newDirectory = projects.appendingPathComponent("copied")
        try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        var copied = project.value; copied.id = UUID(); copied.name = "Copied project"
        try JSONCoding.encode(copied).write(to: newDirectory.appendingPathComponent("project.json"), options: .atomic)
        try await wait { await store.refresh().projects.count == 2 }
        try FileManager.default.removeItem(at: newDirectory)
        try await wait { await store.refresh().projects.count == 1 }
    }

    @Test func droppedEventRecoveryDoesAFullScanAndWritesAreImmediatelyVisible() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try FileStore(root: root)
        _ = await store.reload()
        let first = try await store.save(PresetSet(name: "First"))
        #expect(await store.refresh().presetSets.count == 1)
        let second = try await store.save(PresetSet(name: "Second"))
        #expect(await store.refresh().presetSets.count == 2)
        try await quiet(store)
        let before = await store.ioCounts()
        var changed = first.value; changed.name = "Recovered after event loss"
        try JSONCoding.encode(changed).write(to: URL(fileURLWithPath: first.path), options: .atomic)
        let recovered = await store.refresh(changes: MetadataChanges(rescan: true))
        #expect(recovered.presetSets.contains { $0.value.name == changed.name })
        #expect(recovered.presetSets.contains { $0.value.id == second.value.id })
        #expect(await store.ioCounts().records - before.records == 2)
        // Synchronous save checks still see edits before FSEvents delivers them.
        await #expect(throws: ChauffeurError.self) { try await store.save(first.value, expectedVersion: first.version) }
    }

    @Test func replacedStoreRootRecoversWatchingInsteadOfRemainingStale() async throws {
        let root = temporaryRoot()
        let backup = root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: backup) }
        let store = try FileStore(root: root)
        let set = try await store.save(PresetSet(name: "Before root move"))
        _ = await store.reload(); try await quiet(store)
        try FileManager.default.moveItem(at: root, to: backup)
        try await wait { await store.refresh().presetSets.isEmpty }
        try FileManager.default.copyItem(at: backup, to: root)
        try await wait { await store.refresh().presetSets.first?.value.id == set.value.id }
        try await quiet(store)
        #expect(await store.current().errors.isEmpty)
        var changed = set.value; changed.name = "Watcher reattached"
        try JSONCoding.encode(changed).write(to: URL(fileURLWithPath: set.path), options: .atomic)
        try await wait { await store.refresh().presetSets.first?.value.name == changed.name }
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/tmp/chauffeur-watch-\(UUID())").resolvingSymlinksInPath()
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ChauffeurError("fixture_timeout", "File notification was not observed")
    }
    private func quiet(_ store: FileStore) async throws {
        var unchangedSince = ContinuousClock.now
        var counts = await store.ioCounts()
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            _ = await store.refresh()
            let current = await store.ioCounts()
            if current != counts { counts = current; unchangedSince = .now }
            if ContinuousClock.now - unchangedSince >= .milliseconds(600) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ChauffeurError("fixture_timeout", "Metadata events did not settle")
    }
}
