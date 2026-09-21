import Foundation
import Testing
@testable import ChauffeurCore

struct GlobalMenuHotkeyTests {
    @Test func defaultsToControlSpace() {
        let shortcut = GlobalMenuHotkey()
        #expect(shortcut.enabled)
        #expect(shortcut.keyCode == 49)
        #expect(shortcut.control && !shortcut.command && !shortcut.option && !shortcut.shift)
        #expect(shortcut.displayName == "⌃Space")
    }

    @Test func preferenceRoundTripKeepsDisabledCustomShortcut() throws {
        let name = "chauffeur-hotkey-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(GlobalMenuHotkey.load(from: defaults) == GlobalMenuHotkey())
        let shortcut = GlobalMenuHotkey(enabled: false, keyCode: 40, key: "K", control: false, option: true, shift: true, command: true)
        try shortcut.save(to: defaults)
        #expect(GlobalMenuHotkey.load(from: defaults) == shortcut)
        #expect(shortcut.displayName == "⌥⇧⌘K")
    }

    @Test func rejectsUnmodifiedKeysAndFallsBackFromCorruptPreferences() throws {
        let name = "chauffeur-hotkey-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: GlobalMenuHotkey.preferenceKey)
        #expect(GlobalMenuHotkey.load(from: defaults) == GlobalMenuHotkey())
        let shortcut = GlobalMenuHotkey(keyCode: 0, key: "A", control: false)
        #expect(!shortcut.isValid)
        #expect(!GlobalMenuHotkey(keyCode: 49, key: "Space", control: false, shift: true).isValid)
        #expect(throws: ChauffeurError.self) { try shortcut.save(to: defaults) }
    }
}
