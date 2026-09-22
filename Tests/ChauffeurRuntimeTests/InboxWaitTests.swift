import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct InboxWaitTests {
    private func fixture() async throws -> (Ledger, String, Caller, Session, String, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-inbox-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = try Ledger(path: root.appendingPathComponent("ledger.sqlite").path)
        let a = LedgerTests().session(project: UUID(), group: UUID())
        let b = LedgerTests().session(project: a.projectID, group: a.groupID)
        for session in [a, b] { try await ledger.register(session) }
        let tokenA = try await ledger.issueGrant(sessionID: a.id)
        let tokenB = try await ledger.issueGrant(sessionID: b.id)
        return (ledger, tokenA, try await ledger.authenticate(tokenA), b, tokenB, root)
    }

    private func subscribed(_ ledger: Ledger, count: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await ledger.pendingInboxWaitCount != count && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await ledger.pendingInboxWaitCount == count)
    }

    @Test func arrivalWakesAllWaitersAndAcknowledgementPreventsRedelivery() async throws {
        let (ledger, _, sender, recipient, token, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Task { try await ledger.waitForInbox(token: token, waitSeconds: 300) }
        let second = Task { try await ledger.waitForInbox(token: token, waitSeconds: 300) }
        defer { first.cancel(); second.cancel() }
        try await subscribed(ledger, count: 2)
        let message = try await ledger.send(caller: sender, recipientID: recipient.id, body: "Done", retryKey: "done")
        #expect(try await first.value.map(\.id) == [message.id])
        #expect(try await second.value.map(\.id) == [message.id])
        #expect(await ledger.pendingInboxWaitCount == 0)
        #expect(try await ledger.waitForInbox(token: token, waitSeconds: 300).map(\.id) == [message.id])
        #expect(try await ledger.waitForInbox(token: token, acknowledge: [message.id], waitSeconds: 0).isEmpty)
    }

    @Test func timeoutCancellationAndRevocationReleaseWaiters() async throws {
        let (ledger, _, _, recipient, token, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = ContinuousClock.now
        #expect(try await ledger.waitForInbox(token: token, waitSeconds: 1).isEmpty)
        #expect(start.duration(to: .now) >= .seconds(1))
        let cancelled = Task { try await ledger.waitForInbox(token: token, waitSeconds: 300) }
        try await subscribed(ledger)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await ledger.pendingInboxWaitCount == 0)
        let revoked = Task { try await ledger.waitForInbox(token: token, waitSeconds: 300) }
        defer { revoked.cancel() }
        try await subscribed(ledger)
        try await ledger.revoke(sessionID: recipient.id)
        await #expect(throws: ChauffeurError.self) { try await revoked.value }
        #expect(await ledger.pendingInboxWaitCount == 0)
    }

    @Test func workerFailureWakesControllerWithoutInventingResult() async throws {
        let (ledger, token, parent, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (delegation, _) = try await ledger.reserveDelegation(caller: parent, task: "Work", presetID: UUID(), folderID: UUID(), shareCheckout: true, retryKey: "worker", limit: 4)
        var child = LedgerTests().session(project: parent.scope.projectID, group: parent.scope.groupID, parent: parent.sessionID)
        child.id = delegation.childID
        try await ledger.register(child)
        let waiting = Task { try await ledger.waitForInbox(token: token, waitSeconds: 300) }
        defer { waiting.cancel() }
        try await subscribed(ledger)
        child.state = .failed
        try await ledger.register(child)
        #expect(try await waiting.value.isEmpty)
        #expect(try await ledger.inbox(caller: parent).isEmpty)
        #expect(await ledger.pendingInboxWaitCount == 0)
    }

    @Test func unrelatedInboxDoesNotEndWaitAndBoundsAreEnforced() async throws {
        let (ledger, _, sender, recipient, token, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let waiting = Task { try await ledger.waitForInbox(token: token, waitSeconds: 300) }
        defer { waiting.cancel() }
        try await subscribed(ledger)
        _ = try await ledger.send(caller: sender, recipientID: sender.sessionID, body: "Unrelated", retryKey: "unrelated")
        #expect(await ledger.pendingInboxWaitCount == 1)
        let sent = try await ledger.send(caller: sender, recipientID: recipient.id, body: "Relevant", retryKey: "relevant")
        #expect(try await waiting.value.map(\.id) == [sent.id])
        for seconds in [-1, 301] {
            await #expect(throws: ChauffeurError.self) { try await ledger.waitForInbox(token: token, waitSeconds: seconds) }
        }
    }
}
