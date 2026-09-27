import Foundation
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

struct KeepAwakeManagerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func waitingExpiresWithoutMetadataOrRepeatedEventsRenewingIt() throws {
        let driver = FakePowerAssertion()
        var manager = KeepAwakeManager(driver: driver)
        try manager.setSettings(.init(automatic: true, waitingMinutes: 30), now: now)
        let id = UUID()
        manager.update([.init(id: id, activity: .working, observedAt: now)], now: now)
        #expect(manager.status.assertionHeld)
        manager.update([.init(id: id, activity: .waiting, observedAt: now)], now: now)
        manager.update([.init(id: id, activity: .waiting, observedAt: now.addingTimeInterval(1799))], now: now.addingTimeInterval(1799))
        #expect(manager.status.assertionHeld)
        manager.tick(now: now.addingTimeInterval(1800))
        #expect(!manager.status.assertionHeld)
        #expect(driver.acquisitions == 1 && driver.releases == 1)
        manager.update([.init(id: id, activity: .working, observedAt: now)], now: now.addingTimeInterval(1801))
        #expect(manager.status.assertionHeld)
        manager.update([.init(id: id, activity: .waiting, observedAt: now)], now: now.addingTimeInterval(1802))
        manager.tick(now: now.addingTimeInterval(3601))
        #expect(manager.status.assertionHeld)
    }

    @Test func manualAndAutomaticReasonsAreIndependent() throws {
        var manager = KeepAwakeManager(driver: FakePowerAssertion())
        try manager.setTimer(.init(until: now.addingTimeInterval(3600)), now: now)
        #expect(manager.status.assertionHeld)
        let agent = KeepAwakeAgent(id: UUID(), activity: .working, observedAt: now)
        manager.update([agent], now: now)
        try manager.setSettings(.init(automatic: true), now: now)
        try manager.setTimer(.init(until: nil), now: now)
        #expect(manager.status.assertionHeld && manager.status.manualUntil == nil)
        try manager.setTimer(.init(until: now.addingTimeInterval(3600)), now: now)
        try manager.setSettings(.init(automatic: false), now: now)
        #expect(manager.status.assertionHeld)
        manager.tick(now: now.addingTimeInterval(3600))
        #expect(!manager.status.assertionHeld && manager.status.manualUntil == nil)
    }

    @Test func multipleAgentsAndChangingGraceUseOriginalWaitStart() throws {
        var manager = KeepAwakeManager(driver: FakePowerAssertion())
        let first = KeepAwakeAgent(id: UUID(), activity: .waiting, observedAt: now)
        let second = KeepAwakeAgent(id: UUID(), activity: .working, observedAt: now)
        manager.update([first, second], now: now)
        try manager.setSettings(.init(automatic: true, waitingMinutes: 1), now: now)
        manager.tick(now: now.addingTimeInterval(60))
        #expect(manager.status.qualifyingAgents == 1)
        manager.update([first], now: now.addingTimeInterval(61))
        #expect(!manager.status.assertionHeld)
        try manager.setSettings(.init(automatic: true, waitingMinutes: 2), now: now.addingTimeInterval(61))
        #expect(manager.status.assertionHeld)
        manager.tick(now: now.addingTimeInterval(120))
        #expect(!manager.status.assertionHeld)
    }

    @Test func restartPreservesWaitingAndAbsoluteTimerExpiry() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("awake.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let agent = KeepAwakeAgent(id: UUID(), activity: .waiting, observedAt: now)
        do {
            var manager = KeepAwakeManager(driver: FakePowerAssertion(), file: file)
            manager.update([agent], now: now)
            try manager.setSettings(.init(automatic: true, waitingMinutes: 1), now: now)
            try manager.setTimer(.init(until: now.addingTimeInterval(900)), now: now)
        }
        var restored = KeepAwakeManager(driver: FakePowerAssertion(), file: file)
        restored.update([.init(id: agent.id, activity: .waiting, observedAt: now.addingTimeInterval(100))], now: now.addingTimeInterval(100))
        #expect(restored.status.qualifyingAgents == 0)
        #expect(restored.status.manualUntil == now.addingTimeInterval(900))
        #expect(restored.status.assertionHeld)
        restored.tick(now: now.addingTimeInterval(901))
        #expect(!restored.status.assertionHeld)
    }

    @Test func startupAdoptionDoesNotEraseWaitingDeadlineFromStaleRunningRecord() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("awake.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let id = UUID()
        do {
            var original = KeepAwakeManager(driver: FakePowerAssertion(), file: file)
            original.update([.init(id: id, activity: .waiting, observedAt: now)], now: now)
            try original.setSettings(.init(automatic: true, waitingMinutes: 1), now: now)
        }
        var restored = KeepAwakeManager(driver: FakePowerAssertion(), file: file)
        let restart = now.addingTimeInterval(61)
        // The session file can still say running after the waiting deadline was
        // persisted. Startup inventory then adopts that process as activityUnknown.
        restored.update([.init(id: id, activity: .working, observedAt: now)], now: restart, adopting: true)
        restored.update([.init(id: id, activity: .waiting, observedAt: restart)], now: restart)
        #expect(!restored.status.assertionHeld)
    }

    @Test func failuresAreVisibleAndRetriedWithoutLyingAboutAssertion() throws {
        let driver = FakePowerAssertion()
        driver.failAcquire = true
        var manager = KeepAwakeManager(driver: driver)
        try manager.setTimer(.init(until: now.addingTimeInterval(900)), now: now)
        #expect(!manager.status.assertionHeld && manager.status.error != nil)
        driver.failAcquire = false
        manager.tick(now: now)
        #expect(manager.status.assertionHeld && manager.status.error == nil)
        driver.failRelease = true
        try manager.setTimer(.init(until: nil), now: now)
        #expect(manager.status.assertionHeld && manager.status.error != nil)
        driver.failRelease = false
        manager.tick(now: now)
        #expect(!manager.status.assertionHeld && manager.status.error == nil)
    }

    @Test func invalidSettingsAndFailedPersistenceLeavePolicyUnchanged() throws {
        var manager = KeepAwakeManager(driver: FakePowerAssertion())
        #expect(throws: (any Error).self) { try manager.setSettings(.init(automatic: true, waitingMinutes: 0), now: now) }
        #expect(throws: (any Error).self) { try manager.setSettings(.init(waitingMinutes: 1441), now: now) }
        #expect(throws: (any Error).self) { try manager.setTimer(.init(until: now.addingTimeInterval(86401)), now: now) }
        #expect(throws: (any Error).self) { try manager.setTimer(.init(until: Date(timeIntervalSince1970: .infinity)), now: now) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        manager = KeepAwakeManager(driver: FakePowerAssertion(), file: directory)
        #expect(throws: (any Error).self) { try manager.setSettings(.init(automatic: true), now: now) }
        #expect(!manager.status.settings.automatic && !manager.status.assertionHeld)
    }

    @Test func sessionClassificationExcludesShellsAndFinishedProcesses() throws {
        var session = LedgerTests().session(project: UUID(), group: UUID())
        session.launch.preset.kind = .pi
        session.state = .running
        #expect(KeepAwakeAgent(session)?.activity == .working)
        session.state = .needsAttention
        #expect(KeepAwakeAgent(session)?.activity == .waiting)
        session.state = .turnFinished
        session.waiting = .backgroundTask
        #expect(KeepAwakeAgent(session)?.activity == .working)
        session.waiting = .workers
        #expect(KeepAwakeAgent(session)?.activity == .waiting)
        session.state = .activityUnknown
        #expect(KeepAwakeAgent(session)?.activity == .waiting)
        for state in [SessionState.exited, .failed, .interrupted] {
            session.state = state
            #expect(KeepAwakeAgent(session) == nil)
        }
        session.state = .running
        session.launch.preset.kind = .shell
        #expect(KeepAwakeAgent(session) == nil)
    }

    @Test func unknownActivityUsesBoundedRecordedAge() throws {
        var manager = KeepAwakeManager(driver: FakePowerAssertion())
        let old = KeepAwakeAgent(id: UUID(), activity: .waiting, observedAt: now.addingTimeInterval(-1800))
        manager.update([old], now: now)
        try manager.setSettings(.init(automatic: true), now: now)
        #expect(!manager.status.assertionHeld)
        manager.update([.init(id: old.id, activity: .waiting, observedAt: now)], now: now)
        #expect(!manager.status.assertionHeld)
    }

    @Test func nativeAssertionCanBeAcquiredAndReleased() throws {
        guard ProcessInfo.processInfo.environment["CHAUFFEUR_TEST_POWER_ASSERTION"] == "1" else { return }
        let driver = SystemPowerAssertion()
        try driver.acquire()
        defer { try? driver.release() }
        func assertions() throws -> String {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "assertions"]
            let pipe = Pipe(); process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            return String(decoding: data, as: UTF8.self)
        }
        #expect(try assertions().contains("Chauffeur agents or keep-awake timer"))
        try driver.release()
        #expect(try !assertions().contains("Chauffeur agents or keep-awake timer"))
    }

    @Test func expiredRetryDoesNotReplaceNewerTimer() throws {
        var manager = KeepAwakeManager(driver: FakePowerAssertion())
        try manager.setTimer(.init(until: now.addingTimeInterval(900)), now: now)
        try manager.setTimer(.init(until: now.addingTimeInterval(-1)), now: now)
        #expect(manager.status.manualUntil == now.addingTimeInterval(900))
    }
}

private final class FakePowerAssertion: PowerAssertionDriver, @unchecked Sendable {
    var acquisitions = 0
    var releases = 0
    var failAcquire = false
    var failRelease = false
    func acquire() throws {
        if failAcquire { throw ChauffeurError("power_failed", "Failed to keep awake") }
        acquisitions += 1
    }
    func release() throws {
        if failRelease { throw ChauffeurError("power_failed", "Failed to release") }
        releases += 1
    }
}
