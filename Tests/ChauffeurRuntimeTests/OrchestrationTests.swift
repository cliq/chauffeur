import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct OrchestrationTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-orchestration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func caller(_ session: Session, ledger: Ledger) async throws -> Caller {
        try await ledger.register(session)
        return try await ledger.authenticate(ledger.issueGrant(sessionID: session.id))
    }
    @Test func invalidPromptsFailBeforeAnyDeliveryAndMultilineIsAllowed() throws {
        for prompt in [" \n\t", "text\u{1b}[31m", "text\0", String(repeating: "x", count: 65537)] {
            #expect(throws: ChauffeurError.self) { try TmuxHost.validateFollowUpPrompt(prompt) }
        }
        try TmuxHost.validateFollowUpPrompt("First line\nSecond\tline")
    }
    @Test func turnsReceiptsAndStaleResultsSurviveRestart() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ledger.sqlite").path
        let ledger = try Ledger(path: path)
        let parent = LedgerTests().session(project: UUID(), group: UUID())
        let owner = try await caller(parent, ledger: ledger)
        let item = try await ledger.reserveDelegation(caller: owner, task: "Task", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "launch", limit: 4, model: "custom", reasoningEffort: "custom-effort").0
        var child = LedgerTests().session(project: parent.projectID, group: parent.groupID, parent: parent.id)
        child.id = item.childID; child.delegationID = item.id
        let worker = try await caller(child, ledger: ledger)
        _ = try await ledger.reportResult(caller: worker, delegationID: item.id, result: "First report", retryKey: "report")
        let arguments: JSONValue = .object(["expectedTurnID": .string(item.currentTurnID.uuidString), "prompt": .string("Correct it")])
        var (operation, isNew) = try await ledger.reserveOperation(caller: owner, delegationID: item.id, kind: "follow_up", arguments: arguments, retryKey: "correction")
        #expect(isNew)
        let next = try await ledger.beginTurn(caller: owner, operation: &operation, retryKey: "correction")
        #expect(next.result == nil && next.currentTurnID != item.currentTurnID)
        let reopened = try Ledger(path: path)
        let retry = try await reopened.reserveOperation(caller: owner, delegationID: item.id, kind: "follow_up", arguments: arguments, retryKey: "correction")
        #expect(!retry.1 && retry.0.id == operation.id && retry.0.state == "deliveryUncertain")
        #expect(try await reopened.unresolvedFollowUp(delegationID: item.id)?.id == operation.id)
        await #expect(throws: ChauffeurError.self) {
            try await reopened.reserveOperation(caller: owner, delegationID: item.id, kind: "follow_up", arguments: .object(["expectedTurnID": .string(next.currentTurnID.uuidString), "prompt": .string("Duplicate correction")]), retryKey: "new-key")
        }
        await #expect(throws: ChauffeurError.self) {
            try await reopened.reportResult(caller: worker, delegationID: item.id, result: "Stale", retryKey: "stale", turnID: item.currentTurnID)
        }
        await #expect(throws: ChauffeurError.self) {
            try await reopened.reportResult(caller: worker, delegationID: item.id, result: "Legacy report", retryKey: "legacy")
        }
        let result = try await reopened.reportResult(caller: worker, delegationID: item.id, result: "Corrected", retryKey: "corrected", turnID: next.currentTurnID)
        #expect(result.turnID == next.currentTurnID)
        #expect(try await reopened.unresolvedFollowUp(delegationID: item.id) == nil)
        #expect(try await reopened.latestOperation(delegationID: item.id)?.state == "reported")
        #expect(try await reopened.allMessages().map(\.body) == ["First report", "Corrected"])
        await #expect(throws: ChauffeurError.self) {
            try await reopened.reserveOperation(caller: owner, delegationID: item.id, kind: "close", arguments: arguments, retryKey: "correction")
        }
        await #expect(throws: ChauffeurError.self) {
            try await reopened.reserveDelegation(caller: owner, task: "Task", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "launch", limit: 4, model: "different", reasoningEffort: "custom-effort")
        }
    }
    @Test func recoveryIsScopedExclusiveAndRoutesReportsToNewCoordinator() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try Ledger(path: root.appendingPathComponent("ledger.sqlite").path)
        var parent = LedgerTests().session(project: UUID(), group: UUID())
        let original = try await caller(parent, ledger: ledger)
        let item = try await ledger.reserveDelegation(caller: original, task: "Task", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "launch", limit: 4).0
        var child = LedgerTests().session(project: parent.projectID, group: parent.groupID, parent: parent.id)
        child.id = item.childID; child.delegationID = item.id
        let worker = try await caller(child, ledger: ledger)
        let replacement = LedgerTests().session(project: parent.projectID, group: parent.groupID)
        let owner = try await caller(replacement, ledger: ledger)
        let outsider = try await caller(LedgerTests().session(project: parent.projectID, group: UUID()), ledger: ledger)
        await #expect(throws: ChauffeurError.self) { try await ledger.recoverWorkers(caller: owner, previousCoordinatorID: parent.id, retryKey: "recover") }
        await #expect(throws: ChauffeurError.self) { try await ledger.ownedDelegation(item.id, caller: worker) }
        parent.state = .exited; try await ledger.register(parent)
        await #expect(throws: ChauffeurError.self) { try await ledger.recoverWorkers(caller: outsider, previousCoordinatorID: parent.id, retryKey: "recover") }
        let own = try await ledger.reserveDelegation(caller: owner, task: "Already owned", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "own", limit: 4).0
        let adopted = try await ledger.recoverWorkers(caller: owner, previousCoordinatorID: parent.id, retryKey: "recover")
        #expect(adopted.count == 1 && adopted[0].parentID == parent.id && adopted[0].controllerID == replacement.id)
        let retried = try await ledger.recoverWorkers(caller: owner, previousCoordinatorID: parent.id, retryKey: "recover")
        #expect(retried.map(\.id) == [item.id] && !retried.contains(where: { $0.id == own.id }))
        try await ledger.forget(sessionID: parent.id)
        #expect(try await ledger.allSessions().contains(where: { $0.id == parent.id }) == false)
        #expect(try await ledger.ownedDelegation(item.id, caller: owner).id == item.id)
        #expect(try await ledger.recoverWorkers(caller: owner, previousCoordinatorID: parent.id, retryKey: "recover").map(\.id) == [item.id])
        await #expect(throws: ChauffeurError.self) { try await ledger.ownedDelegation(item.id, caller: original) }
        let reopened = try Ledger(path: root.appendingPathComponent("ledger.sqlite").path)
        #expect(try await reopened.allSessions().contains(where: { $0.id == parent.id }) == false)
        let report = try await ledger.reportResult(caller: worker, delegationID: item.id, result: "Recovered", retryKey: "report")
        #expect(report.recipientID == replacement.id)
        await #expect(throws: ChauffeurError.self) {
            try await ledger.reserveDelegation(caller: owner, task: "Second", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "second", limit: 1)
        }
    }
    @Test func replacementRequiresStoppedPredecessorAndCannotDuplicateIt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try Ledger(path: root.appendingPathComponent("ledger.sqlite").path)
        let parent = LedgerTests().session(project: UUID(), group: UUID())
        let owner = try await caller(parent, ledger: ledger)
        var prior = try await ledger.reserveDelegation(caller: owner, task: "Task", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "first", limit: 4).0
        var child = LedgerTests().session(project: parent.projectID, group: parent.groupID, parent: parent.id)
        child.id = prior.childID; try await ledger.register(child)
        prior.closureOutcome = "replaced"; try await ledger.updateDelegation(prior)
        await #expect(throws: ChauffeurError.self) {
            try await ledger.reserveDelegation(caller: owner, task: "Correct", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "next", limit: 4, predecessorID: prior.id)
        }
        child.state = .interrupted; try await ledger.register(child)
        prior.state = .exited; try await ledger.updateDelegation(prior)
        let next = try await ledger.reserveDelegation(caller: owner, task: "Correct", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "next", limit: 4, predecessorID: prior.id)
        #expect(next.1 && next.0.predecessorID == prior.id)
        #expect(try await ledger.reserveDelegation(caller: owner, task: "Correct", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "next", limit: 4, predecessorID: prior.id).1 == false)
        await #expect(throws: ChauffeurError.self) {
            try await ledger.reserveDelegation(caller: owner, task: "Correct", presetID: parent.launch.preset.id, folderID: parent.folderID, shareCheckout: true, retryKey: "duplicate", limit: 4, predecessorID: prior.id)
        }
    }
    @Test func protectedArchivesSurviveBudgetAndLineReductionUntilDeletion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SnapshotStore(root: root)
        let ids = [UUID(), UUID(), UUID()]
        let protected = Set(ids.prefix(2))
        for id in ids {
            let capture = TerminalSnapshot(sessionID: id, processID: 42, terminalIdentity: "%1", columns: 100, rows: 30, lineLimit: 10000,
                history: (0..<2500).map { "\($0) " + String(repeating: "x", count: 300) }.joined(separator: "\n"), screen: "done")
            try await store.save(capture, settings: RetentionSettings(), liveSessions: [], protectedSessions: protected)
        }
        var reduced = RetentionSettings(); reduced.snapshotBudgetBytes = 1_048_576
        let status = try await store.prune(settings: reduced, liveSessions: [], protectedSessions: protected)
        #expect(status.bytes > reduced.snapshotBudgetBytes && status.files == 2)
        #expect(try await store.read(ids[2]) == nil)
        reduced.scrollbackLines = 100
        _ = try await store.applyRetention(settings: reduced, liveSessions: [], protectedSessions: protected)
        let retained = try #require(await store.read(ids[0]))
        #expect(retained.history.split(separator: "\n").count <= 100 && retained.truncated)
        try await store.delete(ids[0])
        #expect(try await store.read(ids[0]) == nil)
    }
}
