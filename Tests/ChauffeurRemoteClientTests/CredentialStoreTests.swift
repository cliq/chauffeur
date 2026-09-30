import Foundation
import Testing
@testable import ChauffeurRemoteClient

struct CredentialStoreTests {
    @Test func inMemoryKeepsSeveralMacsAndReplacesByHostID() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.loadAll().isEmpty)

        let first = Fixtures.savedHost()
        var second = Fixtures.savedHost()
        second.hostID = UUID(); second.name = "studio"
        try store.save(first)
        try store.save(second)
        #expect(try store.loadAll().map(\.hostID) == [first.hostID, second.hostID])

        // Re-pairing a Mac keeps its place in the list.
        var repaired = first
        repaired.port = 60000
        try store.save(repaired)
        #expect(try store.loadAll().map(\.port) == [60000, second.port])

        try store.remove(hostID: first.hostID)
        #expect(try store.loadAll() == [second])
        try store.remove(hostID: UUID())
        #expect(try store.loadAll() == [second])
    }

    @Test func savedHostSurvivesJSONEncoding() throws {
        let host = Fixtures.savedHost()
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(SavedHost.self, from: data) == host)
    }

    @Test func pendingOperationsAreJournaledPerMac() throws {
        let defaults = try #require(UserDefaults(suiteName: "chauffeur-journal-\(UUID())"))
        let (first, second, shared) = (UUID(), UUID(), UUID())
        UserDefaultsOperationJournal(defaults: defaults).record(shared)
        UserDefaultsOperationJournal.migrateSharedJournal(to: first, defaults: defaults)
        #expect(UserDefaultsOperationJournal.forHost(first, defaults: defaults).pendingKeys() == [shared])
        #expect(UserDefaultsOperationJournal(defaults: defaults).pendingKeys().isEmpty)

        UserDefaultsOperationJournal.forHost(second, defaults: defaults).record(UUID())
        #expect(UserDefaultsOperationJournal.forHost(first, defaults: defaults).pendingKeys() == [shared])
    }
}

struct FileAndFallbackCredentialStoreTests {
    private func sampleHost(name: String = "Mac") -> SavedHost {
        SavedHost(hostID: UUID(), name: name, host: "10.0.0.2", port: 51847, remoteAccessKey: Data(repeating: 7, count: 32),
                  deviceID: UUID(), deviceToken: "token", pairedAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func fileStoreRoundTripsAndRemovesItsFileWhenEmpty() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-cred-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("saved-hosts.json")
        let store = FileCredentialStore(url: url)
        #expect(try store.loadAll().isEmpty)
        let hosts = [sampleHost(), sampleHost(name: "Studio")]
        try store.saveAll(hosts)
        #expect(try store.loadAll() == hosts)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        try store.saveAll([])
        #expect(try store.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func fileStoreReadsTheSingleMacOfEarlierBuildsUntilTheNextSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-cred-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = sampleHost()
        let legacyURL = dir.appendingPathComponent("saved-host.json")
        try JSONEncoder().encode(legacy).write(to: legacyURL)

        let store = FileCredentialStore(url: dir.appendingPathComponent("saved-hosts.json"))
        #expect(try store.loadAll() == [legacy])
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        let added = sampleHost(name: "Studio")
        try store.save(added)
        #expect(try store.loadAll() == [legacy, added])
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test func corruptFileIsReported() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-cred-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("saved-hosts.json")
        try Data("not json".utf8).write(to: url)
        #expect(throws: CredentialStoreError.corruptData) { try FileCredentialStore(url: url).loadAll() }
    }

    private final class FailingStore: CredentialStore {
        let status: OSStatus
        init(status: OSStatus) { self.status = status }
        func loadAll() throws -> [SavedHost] { throw CredentialStoreError.keychain(status) }
        func saveAll(_ hosts: [SavedHost]) throws { throw CredentialStoreError.keychain(status) }
    }

    @Test func fallsBackOnlyForMissingEntitlement() throws {
        let host = sampleHost()
        let fallback = InMemoryCredentialStore()
        let store = FallbackCredentialStore(primary: FailingStore(status: FallbackCredentialStore.missingEntitlement), fallback: fallback)
        try store.save(host)
        #expect(try store.loadAll() == [host])

        let strict = FallbackCredentialStore(primary: FailingStore(status: -25300), fallback: InMemoryCredentialStore())
        #expect(throws: CredentialStoreError.keychain(-25300)) { try strict.save(host) }
    }
}
