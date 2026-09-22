import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct ProgressRegistrationTests {
    @Test func registrationIsOwnedDurableReplaceableAndRemovable() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let session = try await fixture.runtime.launch(fixture.request)
        let token = try await fixture.runtime.ledger.issueGrant(sessionID: session.id)
        let json = fixture.path("progress.json")
        let html = fixture.path("index.html")
        try Data(#"{"title":"Fixture","now":"Working","updated":"2026-09-22T12:00:00Z","phases":[]}"#.utf8).write(to: json)
        try Data("<!doctype html><title>Progress</title>".utf8).write(to: html)
        let arguments: JSONValue = .object(["jsonPath": .string(json.path), "htmlPath": .string(html.path)])
        let registered = try await fixture.runtime.callTool(token: token, name: "chauffeur_register_progress", arguments: arguments)
        #expect(registered["sessionID"].string == session.id.uuidString)
        let repeated = try await fixture.runtime.callTool(token: token, name: "chauffeur_register_progress", arguments: arguments)
        #expect(repeated == registered)
        let reopened = try Ledger(path: fixture.root.appendingPathComponent("runtime/ledger.sqlite").path)
        #expect(try await reopened.allSessions().first { $0.id == session.id }?.progress?.jsonPath == json.path)
        #expect(await fixture.runtime.store.reload().sessions.first { $0.value.id == session.id }?.value.progress?.htmlPath == html.path)
        let discovery = try await fixture.runtime.callTool(token: token, name: "chauffeur_discover", arguments: .object([:]))
        #expect(discovery["progress"]["jsonPath"].string == json.path)
        await #expect(throws: ChauffeurError.self) {
            try await fixture.runtime.callTool(token: token, name: "chauffeur_register_progress", arguments: .object(["jsonPath": .string("/missing/progress.json")]))
        }
        #expect(try await reopened.allSessions().first { $0.id == session.id }?.progress?.htmlPath == html.path)
        var other = LedgerTests().session(project: session.projectID, group: session.groupID)
        other.state = .running
        try await fixture.runtime.ledger.register(other)
        let otherToken = try await fixture.runtime.ledger.issueGrant(sessionID: other.id)
        await #expect(throws: ChauffeurError.self) {
            try await fixture.runtime.callTool(token: otherToken, name: "chauffeur_unregister_progress", arguments: .object(["sessionID": .string(session.id.uuidString)]))
        }
        _ = try await fixture.runtime.callTool(token: token, name: "chauffeur_register_progress", arguments: .object(["jsonPath": .string(json.path)]))
        #expect(try await reopened.allSessions().first { $0.id == session.id }?.progress?.htmlPath == nil)
        for _ in 0..<2 {
            _ = try await fixture.runtime.callTool(token: token, name: "chauffeur_unregister_progress", arguments: .object([:]))
        }
        #expect(try await reopened.allSessions().first { $0.id == session.id }?.progress == nil)
        #expect(FileManager.default.fileExists(atPath: json.path) && FileManager.default.fileExists(atPath: html.path))
        _ = try await fixture.stop()
    }
}
