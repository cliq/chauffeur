import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct ProgressRegistrationTests {
    @Test func bundledScriptRegistersAndUpdatesWithoutCoordinationMCP() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        #expect(!fixture.request.coordinationEnabled)
        let session = try await fixture.runtime.launch(fixture.request)
        #expect(session.launch.preset.integration == .unavailable)
        // This is the credential passed to the fixture CLI by normal launch, not a separate MCP grant.
        let token = try String(contentsOf: fixture.path("probe-token"), encoding: .utf8)
        let server = try IPCServer(root: fixture.root, runtime: fixture.runtime)
        server.start()
        let skillPath = fixture.path(".agents/skills/implementation-progress")
        let script = skillPath.appendingPathComponent("scripts/progress.py")
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(FileManager.default.fileExists(atPath: skillPath.appendingPathComponent("assets/index.html").path))
        let panel = fixture.path("panel")
        let environment = ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path,
                           "CHAUFFEUR_SOCKET": fixture.path("runtime/runtime.sock").path,
                           "CHAUFFEUR_SESSION_TOKEN": token, "CHAUFFEUR_SESSION_ID": session.id.uuidString]
        let created = try await ProcessRunner.run("/usr/bin/python3", [script.path, "init", "--dir", panel.path,
            "--title", "No MCP", "--phase", "Build", "--phase", "Verify"], environment: environment)
        #expect(created.status == 0)
        #expect(created.error.contains("Registered in Chauffeur"))
        let registration = try #require(await fixture.runtime.store.reload().sessions.first { $0.value.id == session.id }?.value.progress)
        #expect(registration.jsonPath == panel.appendingPathComponent("progress.json").path)
        #expect(registration.htmlPath == panel.appendingPathComponent("index.html").path)
        let updated = try await ProcessRunner.run("/usr/bin/python3", [script.path, "now", "--dir", panel.path,
            "Checking results"], environment: environment)
        #expect(updated.status == 0)
        #expect(try ProgressFiles.read(jsonPath: registration.jsonPath).now == "Checking results")
        #expect(try await fixture.runtime.ledger.allSessions().first { $0.id == session.id }?.progress == registration)
        #expect(!(created.output + created.error + updated.output + updated.error).contains(token))
        _ = try await fixture.stop()
    }

    @Test func localRegistrationRejectsForeignSessionSelectorsAndRevokedCredentials() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let session = try await fixture.runtime.launch(fixture.request)
        let token = try String(contentsOf: fixture.path("probe-token"), encoding: .utf8)
        let json = fixture.path("progress.json")
        try Data(#"{"title":"Fixture","now":"Working","updated":"2026-09-22T12:00:00Z","phases":[]}"#.utf8).write(to: json)
        let arguments: JSONValue = .object(["jsonPath": .string(json.path)])
        let params: JSONValue = .object(["token": .string(token), "arguments": arguments])
        let registered = try await fixture.runtime.handle(IPCRequest("registerProgress", params: params))
        #expect(registered["sessionID"].string == session.id.uuidString)
        await #expect(throws: ChauffeurError.self) {
            try await fixture.runtime.handle(IPCRequest("registerProgress", params: .object([
                "token": .string(token), "arguments": .object(["jsonPath": .string(json.path), "sessionID": .string(UUID().uuidString)])
            ])))
        }
        await #expect(throws: ChauffeurError.self) {
            try await fixture.runtime.handle(IPCRequest("registerProgress", params: .object(["arguments": arguments])))
        }
        _ = try await fixture.runtime.handle(IPCRequest("unregisterProgress", params: .object([
            "token": .string(token), "arguments": .object([:])
        ])))
        #expect(try await fixture.runtime.ledger.allSessions().first { $0.id == session.id }?.progress == nil)
        try await fixture.runtime.ledger.revoke(sessionID: session.id)
        await #expect(throws: ChauffeurError.self) {
            try await fixture.runtime.handle(IPCRequest("registerProgress", params: params))
        }
        #expect(FileManager.default.fileExists(atPath: json.path))
        _ = try await fixture.stop()
    }

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
