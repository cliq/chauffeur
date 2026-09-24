#if os(macOS)
import GhosttyKit
import ChauffeurTerminalInterface

/// A semantic key as the hardware key event Ghostty would receive, so Ghostty encodes it for the
/// terminal's live modes (application cursor keys, kitty keyboard protocol, ...).
struct GhosttyKeyPress: Equatable {
    /// macOS virtual key code (`kVK_*`), which Ghostty maps to its physical key.
    var keycode: UInt32
    var mods: ghostty_input_mods_e
    /// The text the key types, for Control chords; `nil` for keys that type nothing.
    var text: String?
    var unshiftedCodepoint: UInt32

    /// `nil` when the action has no key on a US keyboard (Control with a symbol, F13+); callers
    /// send those bytes with `TerminalKeyEncoder` instead.
    init?(_ action: TerminalKeyAction) {
        func key(_ keycode: UInt32, _ mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE) -> (UInt32, ghostty_input_mods_e) { (keycode, mods) }
        let resolved: (UInt32, ghostty_input_mods_e)
        var text: String?
        var codepoint: UInt32 = 0
        switch action {
        case .escape: resolved = key(0x35)
        case .tab: resolved = key(0x30); codepoint = 0x09
        case .backTab: resolved = key(0x30, GHOSTTY_MODS_SHIFT); codepoint = 0x09
        case .enter: resolved = key(0x24); codepoint = 0x0d
        case .backspace: resolved = key(0x33)
        case .forwardDelete: resolved = key(0x75)
        case .up: resolved = key(0x7E)
        case .down: resolved = key(0x7D)
        case .left: resolved = key(0x7B)
        case .right: resolved = key(0x7C)
        case .home: resolved = key(0x73)
        case .end: resolved = key(0x77)
        case .pageUp: resolved = key(0x74)
        case .pageDown: resolved = key(0x79)
        case .function(let number):
            let codes: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
            guard (1...codes.count).contains(number) else { return nil }
            resolved = key(codes[number - 1])
        case .control(let character):
            guard let letter = character.lowercased().first, let code = Self.letterKeycodes[letter],
                  let scalar = letter.unicodeScalars.first else { return nil }
            resolved = key(code, GHOSTTY_MODS_CTRL)
            text = String(letter)
            codepoint = scalar.value
        }
        keycode = resolved.0
        mods = resolved.1
        self.text = text
        unshiftedCodepoint = codepoint
    }

    private static let letterKeycodes: [Character: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
    ]

    /// Sends the press and its release to `surface`.
    func send(to surface: ghostty_surface_t) {
        var input = ghostty_input_key_s()
        input.keycode = keycode
        input.mods = mods
        input.consumed_mods = GHOSTTY_MODS_NONE
        input.unshifted_codepoint = unshiftedCodepoint
        input.composing = false
        input.action = GHOSTTY_ACTION_PRESS
        if let text {
            text.withCString { pointer in
                input.text = pointer
                _ = ghostty_surface_key(surface, input)
            }
        } else {
            input.text = nil
            _ = ghostty_surface_key(surface, input)
        }
        input.action = GHOSTTY_ACTION_RELEASE
        input.text = nil
        _ = ghostty_surface_key(surface, input)
    }
}

#endif
