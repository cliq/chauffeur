import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct InboxHintTests {
    private struct Fixture {
        let root: URL, path: String, ledger: Ledger
        let sender: Caller, recipient: Caller, recipientToken: String
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func send(_ key: String) async throws -> Message {
            try await ledger.send(caller: sender, recipientID: recipient.sessionID, body: "Secret body \(key)", retryKey: key)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-hints-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("ledger.sqlite").path
        let ledger = try Ledger(path: path)
        let a = LedgerTests().session(project: UUID(), group: UUID())
        let b = LedgerTests().session(project: a.projectID, group: a.groupID)
        for session in [a, b] { try await ledger.register(session) }
        let tokenA = try await ledger.issueGrant(sessionID: a.id), tokenB = try await ledger.issueGrant(sessionID: b.id)
        return Fixture(root: root, path: path, ledger: ledger, sender: try await ledger.authenticate(tokenA), recipient: try await ledger.authenticate(tokenB), recipientToken: tokenB)
    }

    @Test func claimsLeaveDeliveryUntouchedAndMentionEachMessageOnce() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let first = try await f.send("one")
        let claimed = try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", toolUseID: "t1")
        #expect(claimed == InboxHintSummary(count: 1, results: 0, block: false))
        let stored = try await f.ledger.message(first.id, caller: f.recipient)
        #expect(stored.state == .queued && stored.receivedAt == nil, "A hint is not a delivery")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", toolUseID: "t2").count == 0)
        // Reading it, acknowledging it, and a new arrival: the total stays one, but the new ID is new.
        _ = try await f.ledger.inbox(caller: f.recipient)
        _ = try await f.ledger.inbox(caller: f.recipient, acknowledge: [first.id])
        _ = try await f.send("two")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", toolUseID: "t3").count == 1)
        // Received mail was already surfaced by chauffeur_inbox and is not hinted again.
        let third = try await f.send("three")
        _ = try await f.ledger.inbox(caller: f.recipient)
        #expect(try await f.ledger.message(third.id, caller: f.recipient).state == .received)
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", toolUseID: "t4").count == 0)
    }

    @Test func cancelledMessagesAndOtherScopesAreNotClaimed() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let message = try await f.send("cancel")
        _ = try await f.ledger.cancelMessage(message.id, caller: f.sender)
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "UserPromptSubmit").count == 0)
        _ = try await f.send("mine")
        // The sender's own outgoing mail is never its hint, nor another group's.
        #expect(try await f.ledger.claimInboxHint(caller: f.sender, event: "UserPromptSubmit").count == 0)
        let outsider = LedgerTests().session(project: f.recipient.scope.projectID, group: UUID())
        try await f.ledger.register(outsider)
        let outsiderCaller = try await f.ledger.authenticate(f.ledger.issueGrant(sessionID: outsider.id))
        #expect(try await f.ledger.claimInboxHint(caller: outsiderCaller, event: "UserPromptSubmit").count == 0)
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "UserPromptSubmit").count == 1)
        await #expect(throws: ChauffeurError.self) { try await f.ledger.claimInboxHint(caller: f.recipient, event: "SessionStart") }
    }

    @Test func workerResultsAreCountedSeparately() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let (delegation, _) = try await f.ledger.reserveDelegation(caller: f.recipient, task: "Work", presetID: UUID(), folderID: UUID(), shareCheckout: true, retryKey: "worker", limit: 4)
        var child = LedgerTests().session(project: f.recipient.scope.projectID, group: f.recipient.scope.groupID, parent: f.recipient.sessionID)
        child.id = delegation.childID
        try await f.ledger.register(child)
        let worker = try await f.ledger.authenticate(f.ledger.issueGrant(sessionID: child.id))
        _ = try await f.ledger.reportResult(caller: worker, delegationID: delegation.id, result: "Done", retryKey: "r1")
        _ = try await f.send("peer")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "UserPromptSubmit") == InboxHintSummary(count: 2, results: 1))
    }

    @Test func retriedHookCallsGetTheirFirstAnswer() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        _ = try await f.send("one")
        let first = try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", nativeTurnID: "turn", toolUseID: "call")
        _ = try await f.send("two")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", nativeTurnID: "turn", toolUseID: "call") == first)
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", nativeTurnID: "turn", toolUseID: "next").count == 1)
    }

    @Test func concurrentClaimsMentionEachMessageOnce() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        for index in 0..<5 { _ = try await f.send("m\(index)") }
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<8 { group.addTask { try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", toolUseID: "p\(index)").count } }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(counts.reduce(0, +) == 5)
    }

    @Test func claudeStopBlocksOnceUntilTheNextPrompt() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "Stop") == InboxHintSummary(), "No mail, no continuation")
        _ = try await f.send("one")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "Stop") == InboxHintSummary(count: 1, results: 0, block: true))
        _ = try await f.send("two")
        // Still in the continued turn: never block twice, and leave the mail for the next prompt.
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "Stop") == InboxHintSummary())
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "UserPromptSubmit").count == 1)
        _ = try await f.send("three")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "Stop").block)
    }

    @Test func codexStopBlocksOncePerNativeTurn() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        _ = try await f.send("one")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "Stop", nativeTurnID: "turn-a").block)
        _ = try await f.send("two")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "Stop", nativeTurnID: "turn-a").block, "A retried call is answered from its receipt")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "PostToolUse", nativeTurnID: "turn-a", toolUseID: "x").count == 1)
        _ = try await f.send("three")
        #expect(try await f.ledger.claimInboxHint(caller: f.recipient, event: "Stop", nativeTurnID: "turn-b").block)
    }

    @Test func claimsSurviveRestartAndPruneWithTheirMessages() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let message = try await f.send("one")
        _ = try await f.ledger.claimInboxHint(caller: f.recipient, event: "Stop")
        let reopened = try Ledger(path: f.path)
        let recipient = try await reopened.authenticate(f.recipientToken)
        #expect(try await reopened.claimInboxHint(caller: recipient, event: "PostToolUse").count == 0)
        #expect(try await reopened.claimInboxHint(caller: recipient, event: "Stop") == InboxHintSummary(), "The stop flag is durable too")
        _ = try await reopened.inbox(caller: recipient)
        _ = try await reopened.inbox(caller: recipient, acknowledge: [message.id])
        #expect(try await reopened.pruneCompletedMessages(olderThan: Date().addingTimeInterval(60)) == 1)
        #expect(try await reopened.hintRowCount() == 0)
    }

    @Test func revokedCredentialsCannotClaim() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        try await f.ledger.revoke(sessionID: f.recipient.sessionID)
        await #expect(throws: ChauffeurError.self) { try await f.ledger.authenticate(f.recipientToken) }
    }
}
