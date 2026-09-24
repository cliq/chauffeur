#if os(macOS)
import AppKit
import GhosttyKit

// Hardware keys go through `interpretKeyEvents` so input methods and dead keys work; the text
// they produce is attached to the key event Ghostty encodes. Adapted from Ghostty's macOS app and
// libghostty-spm (both MIT).
extension GhosttySurfaceView {
    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let translation = translatedEvent(event, surface: surface)
        let composingBefore = hasMarkedText()

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        lastPerformKeyEvent = nil
        interpretKeyEvents([translation])
        syncPreedit(clearIfNeeded: composingBefore)

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts {
                sendKey(action, event: event, translation: translation, text: text, composing: false)
            }
        } else {
            sendKey(action, event: event, translation: translation, text: translation.ghosttyCharacters,
                    composing: hasMarkedText() || composingBefore)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(GHOSTTY_ACTION_RELEASE, event: event, translation: event, text: nil, composing: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface, !hasMarkedText() else { return }
        let modifier: UInt32
        switch event.keyCode {
        case 0x39: modifier = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: modifier = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: modifier = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: modifier = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: modifier = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        var action = GHOSTTY_ACTION_RELEASE
        if Self.ghosttyMods(event.modifierFlags).rawValue & modifier != 0 {
            // For right-side keys, check that this side is the one held.
            let sideMask: UInt32? = switch event.keyCode {
            case 0x3C: UInt32(NX_DEVICERSHIFTKEYMASK)
            case 0x3E: UInt32(NX_DEVICERCTLKEYMASK)
            case 0x3D: UInt32(NX_DEVICERALTKEYMASK)
            case 0x36: UInt32(NX_DEVICERCMDKEYMASK)
            default: nil
            }
            if sideMask.map({ UInt32(truncatingIfNeeded: event.modifierFlags.rawValue) & $0 != 0 }) ?? true {
                action = GHOSTTY_ACTION_PRESS
            }
        }
        var input = keyInput(action, event: event, translationFlags: nil)
        input.text = nil
        _ = ghostty_surface_key(surface, input)
    }

    /// Key equivalents reach the view before the main menu. Only Ghostty bindings (Chauffeur's
    /// word navigation) and the two control chords AppKit never sends to `keyDown` are taken here;
    /// everything else falls through so the app's menu shortcuts win.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }
        if isBinding(event, surface: surface) {
            keyDown(with: event)
            return true
        }
        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control), event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            // A Control chord no menu item claimed comes back a second time with the same
            // timestamp; only then does it belong to the terminal.
            guard event.timestamp != 0, event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) else {
                lastPerformKeyEvent = nil
                return false
            }
            if lastPerformKeyEvent == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
            } else {
                lastPerformKeyEvent = event.timestamp
                return false
            }
        }
        guard let translated = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode
        ) else { return false }
        keyDown(with: translated)
        return true
    }

    /// Editing commands (`insertNewline:`, `deleteBackward:`, ...) are ignored: the key event
    /// itself reaches Ghostty, which encodes it for the terminal.
    override func doCommand(by selector: Selector) {}

    // MARK: Encoding

    private func sendKey(_ action: ghostty_input_action_e, event: NSEvent, translation: NSEvent, text: String?, composing: Bool) {
        guard let surface else { return }
        var input = keyInput(action, event: event, translationFlags: translation.modifierFlags)
        input.composing = composing
        if let text, !text.isEmpty, action != GHOSTTY_ACTION_RELEASE {
            text.withCString { pointer in
                input.text = pointer
                _ = ghostty_surface_key(surface, input)
            }
        } else {
            input.text = nil
            _ = ghostty_surface_key(surface, input)
        }
    }

    private func keyInput(_ action: ghostty_input_action_e, event: NSEvent, translationFlags: NSEvent.ModifierFlags?) -> ghostty_input_key_s {
        var input = ghostty_input_key_s()
        input.action = action
        input.keycode = UInt32(event.keyCode)
        input.mods = Self.ghosttyMods(event.modifierFlags)
        // Modifiers spent producing the text; Control and Command stay visible to the encoder.
        var consumed = translationFlags ?? event.modifierFlags
        consumed.remove([.control, .command])
        input.consumed_mods = Self.ghosttyMods(consumed)
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            input.unshifted_codepoint = scalar.value
        }
        return input
    }

    /// The event with the modifiers Ghostty wants for text translation (`macos-option-as-alt`
    /// turns Option into a plain modifier instead of a character selector).
    private func translatedEvent(_ event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
        let translated = Self.modifierFlags(ghostty_surface_key_translation_mods(surface, Self.ghosttyMods(event.modifierFlags)))
        var flags = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translated.contains(flag) { flags.insert(flag) } else { flags.remove(flag) }
        }
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode
        ) ?? event
    }

    private func isBinding(_ event: NSEvent, surface: ghostty_surface_t) -> Bool {
        var input = keyInput(GHOSTTY_ACTION_PRESS, event: event, translationFlags: nil)
        var flags = ghostty_binding_flags_e(rawValue: 0)
        return (event.characters ?? "").withCString { pointer in
            input.text = pointer
            return ghostty_surface_key_is_binding(surface, input, &flags)
        }
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = UInt32(truncatingIfNeeded: flags.rawValue)
        if raw & UInt32(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt32(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt32(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt32(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    private static func modifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let text = markedText.string
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

// MARK: - NSTextInputClient

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        guard !text.isEmpty else { return }
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface {
            // Text from outside a key event (dictation, the character viewer) goes in as text.
            text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString: markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String: markedText = NSMutableAttributedString(string: plain)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard markedText.length > 0 else { return nil }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: markedText.length))
        actualRange?.pointee = clamped
        return markedText.attributedSubstring(from: clamped)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method places its candidate window: the terminal cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        // Ghostty reports the cell's bottom edge in top-left-origin points.
        let rect = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

extension NSEvent {
    /// The event's text for Ghostty: no text for function keys (AppKit reports them as
    /// private-use characters), and the plain character for Control chords so Ghostty can encode
    /// the physical key.
    var ghosttyCharacters: String? {
        guard let characters else { return nil }
        guard characters.count == 1, let scalar = characters.unicodeScalars.first else { return characters }
        if scalar.value < 0x20 {
            return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
        }
        if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        return characters
    }
}
#endif
