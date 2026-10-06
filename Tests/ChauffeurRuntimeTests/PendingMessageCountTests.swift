import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// A session's unread-mail badge follows its mailbox as soon as it changes, not on
/// the next reconciliation (the fixture runs none).
struct PendingMessageCountTests {
    @Test func countFollowsArrivalAndAcknowledgementAndWakesSubscribers() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let runtime = fixture.runtime
        let recipient = try await runtime.launch(fixture.request)
        let sender = LedgerTests().session(project: recipient.projectID, group: recipient.groupID)
        try await runtime.ledger.register(sender)
        let senderCaller = try await runtime.ledger.authenticate(runtime.ledger.issueGrant(sessionID: sender.id))
        let recipientCaller = try await runtime.ledger.authenticate(runtime.ledger.issueGrant(sessionID: recipient.id))

        let generation = await runtime.changeGeneration
        let started = ContinuousClock.now
        let subscriber = Task { await runtime.waitForChange(after: generation, timeout: .seconds(30)) }
        let message = try await runtime.ledger.send(caller: senderCaller, recipientID: recipient.id, body: "Ready", retryKey: "ready")
        await subscriber.value
        #expect(ContinuousClock.now - started < .seconds(10), "A snapshot subscriber wakes on the change, not its timeout")
        try await fixture.wait { try await fixture.session().pendingMessages == 1 }

        // Read but not acknowledged still awaits the agent.
        _ = try await runtime.ledger.inbox(caller: recipientCaller)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await fixture.session().pendingMessages == 1)
        _ = try await runtime.ledger.inbox(caller: recipientCaller, acknowledge: [message.id])
        try await fixture.wait { try await fixture.session().pendingMessages == 0 }
    }

    @Test func waitingAfterAnOlderGenerationReturnsAtOnce() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let generation = await fixture.runtime.changeGeneration
        _ = try await fixture.runtime.launch(fixture.request)
        let started = ContinuousClock.now
        await fixture.runtime.waitForChange(after: generation, timeout: .seconds(30))
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
