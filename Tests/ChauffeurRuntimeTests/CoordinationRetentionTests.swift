import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// Without Keep finished sessions, a coordinator's finished workers stay only while
/// the coordinator can still use their delegation records; then the group goes.
struct CoordinationRetentionTests {
    private struct Group {
        let fixture: LaunchFixture
        let coordinator: Session
        let token: String
        let delegation: JSONValue
        let workerID: UUID
        var runtime: RuntimeCoordinator { fixture.runtime }
        func sessions() async throws -> [Session] { try await runtime.snapshot()["sessions"].decode([Session].self) }
        func close(_ id: UUID) async throws {
            _ = try await runtime.handle(IPCRequest("closeSession", params: .object(["sessionID": .string(id.uuidString)])))
            try await runtime.reconcile()
        }
    }

    /// A coordinator with one live worker sharing its checkout.
    private func group(keepFinishedSessions: Bool) async throws -> Group {
        let fixture = try await LaunchFixture.make()
        // Delegated workers need a CLI that offers YOLO mode.
        let executable = fixture.path("fixture.py")
        let script = try String(contentsOf: executable, encoding: .utf8)
            .replacingOccurrences(of: "else: print('--resume --add-dir')", with: "else: print('--resume --add-dir --dangerously-skip-permissions')")
        try Data(script.utf8).write(to: executable)
        await fixture.runtime.setEndpoint(port: 4242)
        var settings = RetentionSettings(); settings.keepFinishedSessions = keepFinishedSessions
        _ = try await fixture.runtime.handle(IPCRequest("saveSettings", params: .from(settings)))
        let coordinator = try await fixture.runtime.launch(fixture.request)
        let token = try await fixture.runtime.ledger.issueGrant(sessionID: coordinator.id)
        let delegation = try await fixture.runtime.callTool(token: token, name: "chauffeur_delegate", arguments: .object([
            "task": .string("Check the build"), "presetID": .string(fixture.request.presetID.uuidString),
            "folderID": .string(fixture.request.folderID.uuidString), "shareCheckout": .bool(true), "retryKey": .string("check")]))
        let workerID = try #require(delegation["childID"].string.flatMap(UUID.init(uuidString:)))
        let group = Group(fixture: fixture, coordinator: coordinator, token: token, delegation: delegation, workerID: workerID)
        try await fixture.wait { try await group.sessions().first { $0.id == workerID }?.state.isLive == true }
        return group
    }

    @Test(arguments: [false, true])
    func closedWorkersLastAsLongAsTheirCoordinator(keep: Bool) async throws {
        let group = try await group(keepFinishedSessions: keep); defer { group.fixture.cleanup() }
        _ = try await group.runtime.callTool(token: group.token, name: "chauffeur_close_session", arguments: .object([
            "delegationID": group.delegation["id"], "outcome": .string("accepted"), "reason": .string("Done"), "retryKey": .string("close")]))
        try await group.runtime.reconcile()
        let worker = try #require(try await group.sessions().first { $0.id == group.workerID }, "The live coordinator can still inspect its worker")
        #expect(!worker.state.isLive && worker.closureOutcome == "accepted")
        let status = try await group.runtime.callTool(token: group.token, name: "chauffeur_delegation_status", arguments: .object(["delegationID": group.delegation["id"]]))
        #expect(status["closureOutcome"].string == "accepted")

        try await group.close(group.coordinator.id)
        let remaining = Set(try await group.sessions().map(\.id))
        if keep {
            #expect(remaining.isSuperset(of: [group.coordinator.id, group.workerID]))
        } else {
            #expect(remaining.isDisjoint(with: [group.coordinator.id, group.workerID]))
            #expect(try await group.runtime.snapshots.read(group.workerID) == nil)
        }
    }

    @Test func aClosedCoordinatorWaitsForItsLiveWorker() async throws {
        let group = try await group(keepFinishedSessions: false); defer { group.fixture.cleanup() }
        // The user closes the coordinator's tab while its worker still runs:
        // a new coordinator may still need to recover that worker.
        try await group.close(group.coordinator.id)
        #expect(try await group.sessions().first { $0.id == group.coordinator.id }?.closedAt != nil)

        // Once the worker ends too, nothing needs either record.
        try await group.close(group.workerID)
        #expect(Set(try await group.sessions().map(\.id)).isDisjoint(with: [group.coordinator.id, group.workerID]))
    }
}
