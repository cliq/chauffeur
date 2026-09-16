import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct NotificationTests {
    @Test func testAlertPreservesSessionAndPendingRealNotifications() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-test-notification-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try Ledger(path: root.appendingPathComponent("ledger.sqlite").path)
        var session = LedgerTests().session(project: UUID(), group: UUID())
        session.state = .exited
        try await ledger.register(session)
        let savedSessions = try await ledger.allSessions()
        await #expect(throws: ChauffeurError.self) { try await ledger.testNotification(sessionID: session.id) }
        try await ledger.setNotificationsEnabled(true)
        await #expect(throws: ChauffeurError.self) { try await ledger.testNotification(sessionID: UUID()) }
        let test = try await ledger.testNotification(sessionID: session.id)
        #expect(test.reason == .test && test.route.sessionID == session.id && test.route.projectID == session.projectID)
        #expect(try await ledger.allSessions() == savedSessions)
        #expect(try await ledger.allMessages().isEmpty)
        #expect(try await ledger.testNotification(sessionID: session.id).id == test.id)
        #expect(try await ledger.pendingNotifications().count == 1)
        // A real event takes priority over a queued test, with its own stable OS identifier.
        try await ledger.register(session, notification: .completion)
        let real = try #require(await ledger.pendingNotifications().first)
        #expect(real.identifier != test.identifier)
        await #expect(throws: ChauffeurError.self) { try await ledger.testNotification(sessionID: session.id) }
        #expect(try await ledger.pendingNotifications() == [real])
        try await ledger.acknowledgeNotification(test.id)
        #expect(try await ledger.pendingNotifications() == [real])
        try await ledger.acknowledgeNotification(real.id)
        let repeated = try await ledger.testNotification(sessionID: session.id)
        #expect(repeated.id != test.id && repeated.identifier == test.identifier)
        #expect(try await ledger.allSessions() == savedSessions)
        try await ledger.setNotificationsEnabled(false)
        #expect(try await ledger.pendingNotifications().isEmpty)
    }

    @Test func optInCoalescingDurabilityAndStaleAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-notifications-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ledger.sqlite").path
        let ledger = try Ledger(path: path)
        var session = LedgerTests().session(project: UUID(), group: UUID())
        try await ledger.register(session, notification: .completion)
        #expect(try await !ledger.notificationsEnabled())
        #expect(try await ledger.pendingNotifications().isEmpty)
        try await ledger.setNotificationsEnabled(true)
        #expect(try await ledger.pendingNotifications().isEmpty) // no historical replay
        try await ledger.register(session, notification: .input)
        let first = try #require(await ledger.pendingNotifications().first)
        session.state = .turnFinished
        try await ledger.register(session, notification: .completion)
        try await ledger.acknowledgeNotification(first.id)
        let reopened = try Ledger(path: path)
        let latest = try #require(await reopened.pendingNotifications().first)
        #expect(latest.id != first.id && latest.reason == .completion)
        #expect(latest.identifier == first.identifier)
        #expect(latest.route.projectID == session.projectID && latest.route.sessionID == session.id)
        #expect(try await reopened.pendingNotifications().count == 1)
        try await reopened.acknowledgeNotification(latest.id)
        #expect(try await ledger.pendingNotifications().isEmpty)
        try await ledger.register(session, notification: .failure)
        try await ledger.setNotificationsEnabled(false)
        try await ledger.setNotificationsEnabled(true)
        #expect(try await reopened.pendingNotifications().isEmpty)
        // Snapshot/state persistence alone never emits a notice.
        try await ledger.register(session)
        #expect(try await ledger.pendingNotifications().isEmpty)
    }

    @Test func messageRetriesDoNotReplayAlertsOrExposeMessageBodies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-message-notifications-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try Ledger(path: root.appendingPathComponent("ledger.sqlite").path)
        let a = LedgerTests().session(project: UUID(), group: UUID())
        let b = LedgerTests().session(project: a.projectID, group: a.groupID)
        let outsider = LedgerTests().session(project: a.projectID, group: UUID())
        for session in [a, b, outsider] { try await ledger.register(session) }
        try await ledger.setNotificationsEnabled(true)
        let caller = try await ledger.authenticate(ledger.issueGrant(sessionID: a.id))
        _ = try await ledger.send(caller: caller, recipientID: b.id, body: "private message content", retryKey: "one")
        let notice = try #require(await ledger.pendingNotifications().first)
        #expect(notice.reason == .message && notice.route.sessionID == b.id)
        #expect(!String(decoding: try JSONCoding.encode(notice), as: UTF8.self).contains("private message content"))
        try await ledger.acknowledgeNotification(notice.id)
        _ = try await ledger.send(caller: caller, recipientID: b.id, body: "private message content", retryKey: "one")
        #expect(try await ledger.pendingNotifications().isEmpty)
        await #expect(throws: ChauffeurError.self) {
            try await ledger.send(caller: caller, recipientID: outsider.id, body: "cross-group", retryKey: "two")
        }
        #expect(try await ledger.pendingNotifications().isEmpty)
    }
}
