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
