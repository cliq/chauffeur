import Foundation
import Testing
@testable import ChauffeurRemoteClient

struct CredentialStoreTests {
    @Test func inMemoryRoundTrip() throws {
        let store = InMemoryCredentialStore()
        #expect(try store.load() == nil)

        let host = Fixtures.savedHost()
        try store.save(host)
        #expect(try store.load() == host)
        #expect(try store.load()?.id == host.hostID)

        var updated = host
        updated.port = 60000
        try store.save(updated)
        #expect(try store.load()?.port == 60000)

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func savedHostSurvivesJSONEncoding() throws {
        let host = Fixtures.savedHost()
        let data = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(SavedHost.self, from: data) == host)
    }
}

struct FileAndFallbackCredentialStoreTests {
    private func sampleHost() -> SavedHost {
        SavedHost(hostID: UUID(), name: "Mac", host: "10.0.0.2", port: 51847, remoteAccessKey: Data(repeating: 7, count: 32),
                  deviceID: UUID(), deviceToken: "token", pairedAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func fileStoreRoundTripsAndClears() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-cred-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileCredentialStore(url: dir.appendingPathComponent("saved-host.json"))
        #expect(try store.load() == nil)
        let host = sampleHost()
        try store.save(host)
        #expect(try store.load() == host)
        try store.clear()
        #expect(try store.load() == nil)
    }

    private final class FailingStore: CredentialStore {
        let status: OSStatus
        init(status: OSStatus) { self.status = status }
        func load() throws -> SavedHost? { throw CredentialStoreError.keychain(status) }
        func save(_ host: SavedHost) throws { throw CredentialStoreError.keychain(status) }
        func clear() throws { throw CredentialStoreError.keychain(status) }
    }

    @Test func fallsBackOnlyForMissingEntitlement() throws {
        let host = sampleHost()
        let fallback = InMemoryCredentialStore()
        let store = FallbackCredentialStore(primary: FailingStore(status: FallbackCredentialStore.missingEntitlement), fallback: fallback)
        try store.save(host)
        #expect(try store.load() == host)

        let strict = FallbackCredentialStore(primary: FailingStore(status: -25300), fallback: InMemoryCredentialStore())
        #expect(throws: CredentialStoreError.keychain(-25300)) { try strict.save(host) }
    }
}
