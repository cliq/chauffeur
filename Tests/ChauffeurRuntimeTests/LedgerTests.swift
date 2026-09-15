import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct LedgerTests {
    func session(project: UUID, group: UUID, parent: UUID? = nil) -> Session {
        let set = PresetSet(name: "Shared")
        let preset = AgentPreset(setID: set.id, name: "Fixture", kind: .codex, executable: "/bin/cat", configurationDirectory: "/tmp")
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat", executableVersion: "fixture", workingDirectory: "/tmp", additionalPaths: [])
        var value = Session(projectID: project, groupID: group, title: "Fixture", launch: launch, folderID: UUID())
        value.state = .activityUnknown; value.parentID = parent; return value
    }
    @Test func isolationDurabilityRetriesAndAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-ledger-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ledger.sqlite").path
        let ledger = try Ledger(path: path)
        let project = UUID(), group = UUID()
        let a = session(project: project, group: group), b = session(project: project, group: group)
        let outsider = session(project: project, group: UUID()), otherProject = session(project: UUID(), group: group)
        for value in [a, b, outsider, otherProject] { try await ledger.register(value) }
        let tokenA = try await ledger.issueGrant(sessionID: a.id)
        let tokenB = try await ledger.issueGrant(sessionID: b.id)
        let tokenOut = try await ledger.issueGrant(sessionID: outsider.id)
        let callerA = try await ledger.authenticate(tokenA), callerB = try await ledger.authenticate(tokenB), callerOut = try await ledger.authenticate(tokenOut)
        #expect(try await ledger.peers(callerA).count == 2)
        for id in [outsider.id, otherProject.id] {
            await #expect(throws: ChauffeurError.self) { try await ledger.send(caller: callerA, recipientID: id, body: "secret", retryKey: "cross-group") }
        }
        let sent = try await ledger.send(caller: callerA, recipientID: b.id, body: "Context", references: ["/repo/file.swift"], retryKey: "stable")
        let retried = try await ledger.send(caller: callerA, recipientID: b.id, body: "Context", references: ["/repo/file.swift"], retryKey: "stable")
        #expect(sent.id == retried.id)
        #expect(sent.state == .queued)
        await #expect(throws: ChauffeurError.self) { try await ledger.send(caller: callerA, recipientID: b.id, body: "Different", retryKey: "stable") }
        await #expect(throws: ChauffeurError.self) { try await ledger.message(sent.id, caller: callerOut) }
        await #expect(throws: ChauffeurError.self) { try await ledger.inbox(caller: callerB, acknowledge: [sent.id]) }
        // Opening a fresh connection proves COMMIT visibility and persistence.
        let reopened = try Ledger(path: path)
        let afterRestart = try await reopened.authenticate(tokenB)
        let inbox = try await reopened.inbox(caller: afterRestart)
        #expect(inbox.map(\.id) == [sent.id])
        #expect(inbox.first?.state == .received)
        await #expect(throws: ChauffeurError.self) { try await ledger.inbox(caller: callerA, acknowledge: [sent.id]) }
        #expect(try await reopened.inbox(caller: afterRestart, acknowledge: [sent.id]).isEmpty)
        #expect(try await ledger.message(sent.id, caller: callerA).state == .acknowledged)
        // Cleanup cannot turn a retry of old accepted work into a new delivery.
        #expect(try await ledger.pruneCompletedMessages(olderThan: Date().addingTimeInterval(1)) == 1)
        await #expect(throws: ChauffeurError.self) { try await ledger.send(caller: callerA, recipientID: b.id, body: "Context", references: ["/repo/file.swift"], retryKey: "stable") }
        #expect(try await ledger.allMessages().isEmpty)
        try await ledger.revoke(sessionID: a.id)
        await #expect(throws: ChauffeurError.self) { try await ledger.authenticate(tokenA) }
        await #expect(throws: ChauffeurError.self) { try await ledger.authenticate("") }
        await #expect(throws: ChauffeurError.self) { try await ledger.authenticate("guessed") }
        var stopped = b; stopped.state = .exited; try await ledger.register(stopped)
        await #expect(throws: ChauffeurError.self) { try await ledger.authenticate(tokenB) }
    }
    @Test func delegationReservationIsBoundedAndIdempotent() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-delegate-\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let ledger = try Ledger(path: path)
        let parent = session(project: UUID(), group: UUID())
        try await ledger.register(parent)
        let token = try await ledger.issueGrant(sessionID: parent.id)
        let caller = try await ledger.authenticate(token)
        let presetID = UUID(), folderID = UUID()
        let first = try await ledger.reserveDelegation(caller: caller, task: "Task", presetID: presetID, folderID: folderID, shareCheckout: false, retryKey: "retry", limit: 1)
        let retry = try await ledger.reserveDelegation(caller: caller, task: "Task", presetID: presetID, folderID: folderID, shareCheckout: false, retryKey: "retry", limit: 1)
        #expect(first.0.id == retry.0.id && first.1 && !retry.1)
        await #expect(throws: ChauffeurError.self) { try await ledger.reserveDelegation(caller: caller, task: "Second", presetID: presetID, folderID: folderID, shareCheckout: false, retryKey: "new", limit: 1) }
        var child = session(project: parent.projectID, group: parent.groupID, parent: parent.id)
        child.id = first.0.childID; try await ledger.register(child)
        let childToken = try await ledger.issueGrant(sessionID: child.id), childCaller = try await ledger.authenticate(childToken)
        await #expect(throws: ChauffeurError.self) { try await ledger.reserveDelegation(caller: childCaller, task: "Grandchild", presetID: presetID, folderID: folderID, shareCheckout: false, retryKey: "bad", limit: 4) }
        var running = first.0; running.state = .running; try await ledger.updateDelegation(running)
        let report = try await ledger.reportResult(caller: childCaller, delegationID: running.id, result: "Done", retryKey: "result")
        #expect(report.senderID == child.id && report.recipientID == parent.id)
        #expect(try await ledger.delegation(running.id, caller: caller).state == .resultReported)
        // Result does not mean child execution ended; it still counts as live.
        await #expect(throws: ChauffeurError.self) { try await ledger.reserveDelegation(caller: caller, task: "Second", presetID: presetID, folderID: folderID, shareCheckout: false, retryKey: "new", limit: 1) }
        var changed = child; changed.groupID = UUID()
        await #expect(throws: ChauffeurError.self) { try await ledger.register(changed) }
    }
}
