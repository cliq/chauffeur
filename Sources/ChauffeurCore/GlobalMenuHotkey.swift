import Foundation

/// Local UI preference shared by the main app and its menu bar helper.
public struct GlobalMenuHotkey: Codable, Equatable, Sendable {
    public static let preferenceKey = "globalMenuHotkey"
    public static let statusKey = "globalMenuHotkeyStatus"
    public static let recordingUntilKey = "globalMenuHotkeyRecordingUntil"
    public static let changedNotification = "dev.chauffeur.globalMenuHotkeyChanged"

    public var enabled: Bool
    public var keyCode: UInt32
    public var key: String
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool

    public init(enabled: Bool = true, keyCode: UInt32 = 49, key: String = "Space", control: Bool = true,
                option: Bool = false, shift: Bool = false, command: Bool = false) {
        self.enabled = enabled; self.keyCode = keyCode; self.key = key
        self.control = control; self.option = option; self.shift = shift; self.command = command
    }
    public var isValid: Bool { keyCode <= 127 && !key.isEmpty && (control || option || command) }
    public var displayName: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key
    }
    public static func load(from preferences: UserDefaults) -> Self {
        guard let data = preferences.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return Self() }
        return value
    }
    public func save(to preferences: UserDefaults) throws {
        guard isValid else { throw ChauffeurError("invalid_hotkey", "Include Control, Option, or Command in the shortcut.") }
        preferences.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey)
        preferences.synchronize()
    }
}

public struct GlobalMenuHotkeyStatus: Codable, Sendable {
    public let configuration: GlobalMenuHotkey
    public let error: String?
    public init(configuration: GlobalMenuHotkey, error: String?) {
        self.configuration = configuration; self.error = error
    }
}
