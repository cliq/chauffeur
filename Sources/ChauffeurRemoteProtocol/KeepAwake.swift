import Foundation

public struct KeepAwakeSettings: Codable, Equatable, Sendable {
    public var automatic: Bool
    public var waitingMinutes: Int

    public init(automatic: Bool = false, waitingMinutes: Int = 30) {
        self.automatic = automatic
        self.waitingMinutes = waitingMinutes
    }
}

public struct KeepAwakeStatus: Codable, Equatable, Sendable {
    public var settings: KeepAwakeSettings
    public var manualUntil: Date?
    public var qualifyingAgents: Int
    public var assertionHeld: Bool
    public var error: String?

    public init(
        settings: KeepAwakeSettings,
        manualUntil: Date? = nil,
        qualifyingAgents: Int,
        assertionHeld: Bool,
        error: String? = nil
    ) {
        self.settings = settings
        self.manualUntil = manualUntil
        self.qualifyingAgents = qualifyingAgents
        self.assertionHeld = assertionHeld
        self.error = error
    }
}

public struct KeepAwakeTimerRequest: Codable, Equatable, Sendable {
    public var until: Date?

    public init(until: Date?) {
        self.until = until
    }
}
