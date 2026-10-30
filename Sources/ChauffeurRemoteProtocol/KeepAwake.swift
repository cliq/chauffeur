import Foundation

public struct KeepAwakeSettings: Codable, Equatable, Sendable {
    public var automatic: Bool
    public var waitingMinutes: Int
    /// Also keeps the display from sleeping while protection is active.
    public var keepScreenAwake: Bool

    public init(automatic: Bool = false, waitingMinutes: Int = 30, keepScreenAwake: Bool = false) {
        self.automatic = automatic
        self.waitingMinutes = waitingMinutes
        self.keepScreenAwake = keepScreenAwake
    }

    private enum CodingKeys: String, CodingKey { case automatic, waitingMinutes, keepScreenAwake }

    // Saved settings and older clients predate `keepScreenAwake`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try container.decode(Bool.self, forKey: .automatic)
        waitingMinutes = try container.decode(Int.self, forKey: .waitingMinutes)
        keepScreenAwake = try container.decodeIfPresent(Bool.self, forKey: .keepScreenAwake) ?? false
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
