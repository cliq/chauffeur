import Foundation
import IOKit.pwr_mgt
import ChauffeurCore
import ChauffeurRemoteProtocol

/// Used only by the runtime actor. The driver owns the native assertion, so
/// destroying the runtime also releases it without depending on an app window.
protocol PowerAssertionDriver: Sendable {
    func acquire() throws
    func release() throws
}

final class SystemPowerAssertion: PowerAssertionDriver, @unchecked Sendable {
    private var assertion: IOPMAssertionID?
    func acquire() throws {
        guard assertion == nil else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Chauffeur agents or keep-awake timer" as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw ChauffeurError("keep_awake_failed", "macOS could not prevent idle sleep (\(result)).")
        }
        assertion = id
    }
    func release() throws {
        guard let id = assertion else { return }
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else {
            throw ChauffeurError("keep_awake_failed", "macOS could not release sleep protection (\(result)).")
        }
        assertion = nil
    }
    deinit { if let assertion { IOPMAssertionRelease(assertion) } }
}

struct KeepAwakeAgent: Sendable {
    enum Activity: Sendable { case working, waiting }
    var id: UUID
    var activity: Activity
    var observedAt: Date

    init(id: UUID, activity: Activity, observedAt: Date) {
        self.id = id; self.activity = activity; self.observedAt = observedAt
    }

    init?(_ session: Session) {
        guard session.launch.preset.kind.isAgent, session.state.isLive,
              session.closedAt == nil, session.closureOutcome == nil else { return nil }
        id = session.id
        observedAt = session.updatedAt
        switch session.state {
        case .starting, .running: activity = .working
        case .turnFinished where session.waiting == .backgroundTask: activity = .working
        default: activity = .waiting
        }
    }
}

/// Synchronous, runtime-actor-owned policy. No suspension between deciding which
/// sessions qualify and updating the assertion or saved policy.
struct KeepAwakeManager {
    private struct Saved: Codable, Equatable {
        var settings = KeepAwakeSettings()
        var manualUntil: Date?
        var waitingSince: [UUID: Date] = [:]
    }
    private var saved = Saved()
    private var agents: [KeepAwakeAgent] = []
    private var held = false
    private var qualifyingAgents = 0
    private var storageError: String?
    private var driverError: String?
    private var needsSave = false
    private let driver: any PowerAssertionDriver
    private let file: URL?

    init(driver: any PowerAssertionDriver = SystemPowerAssertion(), file: URL? = nil) {
        self.driver = driver; self.file = file
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do {
                let value = try JSONCoding.decode(Saved.self, from: Data(contentsOf: file))
                try Self.validate(value.settings)
                saved = value
            } catch { storageError = "Could not load Keep Awake settings: \(error.localizedDescription)" }
        }
    }

    var status: KeepAwakeStatus {
        KeepAwakeStatus(settings: saved.settings, manualUntil: saved.manualUntil,
                        qualifyingAgents: qualifyingAgents, assertionHeld: held,
                        error: storageError ?? driverError)
    }

    static func validate(_ settings: KeepAwakeSettings) throws {
        guard (1...1440).contains(settings.waitingMinutes) else {
            throw ChauffeurError("invalid_argument", "Waiting time must be between 1 and 1,440 minutes.")
        }
    }

    mutating func setSettings(_ settings: KeepAwakeSettings, now: Date) throws {
        try Self.validate(settings)
        var proposed = saved; proposed.settings = settings
        try write(proposed)
        saved = proposed; needsSave = false; storageError = nil
        tick(now: now)
    }

    mutating func setTimer(_ request: KeepAwakeTimerRequest, now: Date) throws {
        if let until = request.until {
            let remaining = until.timeIntervalSince(now)
            guard remaining.isFinite, remaining <= 86400 else {
                throw ChauffeurError("invalid_argument", "Choose a keep-awake duration up to 24 hours.")
            }
            // An expired retry must not clear or extend a subsequently set timer.
            guard remaining > 0 else { tick(now: now); return }
        }
        var proposed = saved; proposed.manualUntil = request.until
        try write(proposed)
        saved = proposed; needsSave = false; storageError = nil
        tick(now: now)
    }

    mutating func update(_ observations: [KeepAwakeAgent], now: Date, adopting: Bool = false) {
        // Restored session files can lag the durable waiting timestamps. Until
        // startup reconciles terminal ownership, a saved running state is not
        // evidence of new work and must not erase a previous waiting deadline.
        let current = observations.map { observation in
            var value = observation
            if adopting { value.activity = .waiting }
            return value
        }
        let previousIDs = Set(agents.map(\.id))
        agents = current
        let ids = Set(current.map(\.id))
        let before = saved
        saved.waitingSince = saved.waitingSince.filter { ids.contains($0.key) }
        for agent in current {
            switch agent.activity {
            case .working: saved.waitingSince.removeValue(forKey: agent.id)
            case .waiting:
                if saved.waitingSince[agent.id] == nil {
                    // First observation of a legacy session uses its recorded age.
                    // A live work -> wait transition uses the actual transition time.
                    saved.waitingSince[agent.id] = previousIDs.contains(agent.id) ? now : min(now, agent.observedAt)
                }
            }
        }
        needsSave = needsSave || saved != before
        tick(now: now)
    }

    mutating func tick(now: Date) {
        if let until = saved.manualUntil, until <= now {
            saved.manualUntil = nil; needsSave = true
        }
        if needsSave {
            do { try write(saved); needsSave = false; storageError = nil }
            catch { storageError = "Could not save Keep Awake state: \(error.localizedDescription)" }
        }
        qualifyingAgents = saved.settings.automatic ? agents.filter { agent in
            switch agent.activity {
            case .working: return true
            case .waiting:
                guard let since = saved.waitingSince[agent.id] else { return false }
                return now.timeIntervalSince(since) < Double(saved.settings.waitingMinutes) * 60
            }
        }.count : 0
        let requested = qualifyingAgents > 0 || saved.manualUntil != nil
        do {
            if requested && !held { try driver.acquire(); held = true }
            else if !requested && held { try driver.release(); held = false }
            driverError = nil
        } catch { driverError = error.localizedDescription }
    }

    private func write(_ value: Saved) throws {
        guard let file else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONCoding.encode(value).write(to: file, options: .atomic)
    }
}
