import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct LaunchSessionToolTests {
    @Test func launchedSessionsBelongToTheUserAndRetriesReturnTheSameSession() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        #expect(MCPTools.definitions.contains { $0["name"].string == "chauffeur_launch_session" })
        let coordinator = try await fixture.runtime.launch(fixture.request)
        let token = try await fixture.runtime.ledger.issueGrant(sessionID: coordinator.id)
        let arguments: [String: JSONValue] = [
            "task": .string("Fix the flaky test"), "title": .string("Flaky test"), "presetID": .string(fixture.request.presetID.uuidString),
            "folderID": .string(fixture.request.folderID.uuidString), "retryKey": .string("flaky")
        ]
        func call(_ arguments: [String: JSONValue]) async throws -> JSONValue {
            try await fixture.runtime.callTool(token: token, name: "chauffeur_launch_session", arguments: .object(arguments))
        }

        // The fixture runs no MCP service, so the coordinated launch is refused after its record is saved.
        do {
            _ = try await call(arguments)
            Issue.record("The fixture cannot start a coordinated session")
        } catch let error as ChauffeurError { #expect(error.code == "integration_unavailable") }
        let launched = try #require(await fixture.runtime.store.reload().sessions.first { $0.value.launchedBySessionID == coordinator.id }?.value)
        #expect(launched.parentID == nil && launched.delegationID == nil)
        #expect(launched.title == "Flaky test" && launched.initialTask == "Fix the flaky test")
        #expect(launched.groupID == coordinator.groupID && launched.coordinationEnabled)
        #expect(try await fixture.runtime.ledger.allDelegations().isEmpty)

        let retried = try await call(arguments)
        #expect(retried["sessionID"].string == launched.id.uuidString && retried["coordinated"] == .bool(false))
        var changed = arguments; changed["task"] = .string("Something else")
        do {
            _ = try await call(changed)
            Issue.record("A retry key belongs to one launch")
        } catch let error as ChauffeurError { #expect(error.code == "retry_conflict") }
    }
}
