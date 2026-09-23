import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct WorkWaitTests {
    private struct Fixture {
        let root: URL, ledger: Ledger, coordinator: Caller, token: String, peer: Caller
        let delegation: Delegation, worker: Caller
        var child: Session
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func fixture() async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-work-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = try Ledger(path: root.appendingPathComponent("ledger.sqlite").path)
        let coordinator = LedgerTests().session(project: UUID(), group: UUID())
        let peer = LedgerTests().session(project: coordinator.projectID, group: coordinator.groupID)
        for session in [coordinator, peer] { try await ledger.register(session) }
        let token = try await ledger.issueGrant(sessionID: coordinator.id)
        let coordinatorCaller = try await ledger.authenticate(token)
        let (delegation, _) = try await ledger.reserveDelegation(caller: coordinatorCaller, task: "Audit", presetID: UUID(), folderID: UUID(), shareCheckout: true, retryKey: "worker", limit: 4)
        var child = LedgerTests().session(project: coordinator.projectID, group: coordinator.groupID, parent: coordinator.id)
        child.id = delegation.childID; child.title = "Dependency audit"; child.state = .running
        try await ledger.register(child)
        return Fixture(root: root, ledger: ledger, coordinator: coordinatorCaller, token: token,
                       peer: try await ledger.authenticate(ledger.issueGrant(sessionID: peer.id)), delegation: delegation,
                       worker: try await ledger.authenticate(ledger.issueGrant(sessionID: child.id)), child: child)
    }
    private func waiting(_ ledger: Ledger, count: Int = 1) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await ledger.pendingWorkWaitCount != count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await ledger.pendingWorkWaitCount == count)
    }

    @Test func aResultIsPrintedDeliveredAndKeptOnTheDelegation() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let wait = Task { try await f.ledger.waitForWork(token: f.token, milestones: true, timeoutSeconds: 60) }
        try await waiting(f.ledger)
        // A worker finishing its turn after reporting is covered by the result itself.
        let message = try await f.ledger.reportResult(caller: f.worker, delegationID: f.delegation.id, result: "Audit complete: 3 pods", retryKey: "r1")
        let report = try await wait.value
        #expect(report.reason == .work && report.queuedMessages == 0 && report.workers.isEmpty)
        #expect(report.results == [WorkReport.Result(messageID: message.id, delegationID: f.delegation.id, worker: "Dependency audit", body: "Audit complete: 3 pods")])
        #expect(try await f.ledger.message(message.id, caller: f.coordinator).state == .acknowledged)
        #expect(try await f.ledger.delegation(f.delegation.id, caller: f.coordinator).result == "Audit complete: 3 pods")
        #expect(try await f.ledger.inbox(caller: f.coordinator).isEmpty, "Nothing is delivered twice")
        #expect(WorkReportFormatter.text(report).contains("Audit complete: 3 pods"))
    }

    @Test func peerMailAndOversizedResultsStayQueuedAndAreCounted() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let big = String(repeating: "x", count: WorkReport.printedResultBudget + 1)
        let result = try await f.ledger.reportResult(caller: f.worker, delegationID: f.delegation.id, result: big, retryKey: "big")
        let mail = try await f.ledger.send(caller: f.peer, recipientID: f.coordinator.sessionID, body: "Peer note", retryKey: "peer")
        let report = try await f.ledger.waitForWork(token: f.token, milestones: true, timeoutSeconds: 60)
        #expect(report.results.isEmpty && report.queuedMessages == 2, "Already-queued mail answers at once")
        for id in [result.id, mail.id] { #expect(try await f.ledger.message(id, caller: f.coordinator).state == .queued) }
        #expect(!WorkReportFormatter.text(report).contains("Peer note"))
    }

    @Test func workerStateChangesWakeButOnlyForThisCoordinatorsWorkers() async throws {
        var f = try await fixture(); defer { f.cleanup() }
        let (ledger, token) = (f.ledger, f.token)
        let wait = Task { try await ledger.waitForWork(token: token, milestones: true, timeoutSeconds: 60) }
        try await waiting(f.ledger)
        f.child.state = .failed
        try await f.ledger.register(f.child)
        let report = try await wait.value
        #expect(report.workers == [WorkReport.Worker(delegationID: f.delegation.id, worker: "Dependency audit", state: .failed)])
        #expect(WorkReportFormatter.text(report).contains("is now failed"))
    }

    @Test func milestonesWakeButActivityTextDoesNot() async throws {
        var f = try await fixture(); defer { f.cleanup() }
        let path = f.root.appendingPathComponent("progress.json")
        func write(_ now: String, _ state: String) throws {
            let data = try JSONSerialization.data(withJSONObject: ["title": "Audit", "now": now, "updated": "2026-09-23T10:00:00Z",
                "phases": [["title": "Inventory", "detail": "", "state": state, "steps": []]]])
            try data.write(to: path, options: .atomic)
        }
        try write("Starting", "active")
        f.child.progress = ProgressRegistration(jsonPath: path.path)
        try await f.ledger.register(f.child)
        let (ledger, token) = (f.ledger, f.token)
        let wait = Task { try await ledger.waitForWork(token: token, milestones: true, timeoutSeconds: 60) }
        defer { wait.cancel() }
        try await waiting(f.ledger)
        try write("Reading Podfile", "active")
        try await Task.sleep(for: .milliseconds(700))
        #expect(await f.ledger.pendingWorkWaitCount == 1)
        try write("Reading Podfile", "done")
        let report = try await wait.value
        #expect(report.milestones == ["Dependency audit"] && report.results.isEmpty)
    }

    @Test func timeoutReplacementRevocationAndAGoneProcessEndTheWait() async throws {
        let f = try await fixture(); defer { f.cleanup() }
        let timedOut = try await f.ledger.waitForWork(token: f.token, milestones: true, timeoutSeconds: 1)
        #expect(timedOut.reason == .timeout && timedOut.isEmpty)

        let first = Task { try await f.ledger.waitForWork(token: f.token, milestones: true, timeoutSeconds: 60) }
        try await waiting(f.ledger)
        let second = Task { try await f.ledger.waitForWork(token: f.token, milestones: true, timeoutSeconds: 60) }
        #expect(try await first.value.reason == .replaced)
        try await waiting(f.ledger)
        try await f.ledger.revoke(sessionID: f.coordinator.sessionID)
        #expect(try await second.value.reason == .ended)

        let fresh = try await fixture(); defer { fresh.cleanup() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run(); process.waitUntilExit()
        let start = ContinuousClock.now
        let gone = try await fresh.ledger.waitForWork(token: fresh.token, milestones: true, timeoutSeconds: 60, processID: process.processIdentifier)
        #expect(gone.reason == .ended && start.duration(to: .now) < .seconds(6))
        #expect(await fresh.ledger.pendingWorkWaitCount == 0)
        #expect(await fresh.ledger.pendingInboxWaitCount == 0)
    }
}
