import AppKit
import ChauffeurCore
@preconcurrency import SwiftTerm

/// Updates default terminal colors without replacing the terminal or its buffer.
final class ThemedTerminalView: TerminalView {
    private var appliedAppearance: NSAppearance.Name?
    var acceptsFileDrops = false {
        didSet {
            if acceptsFileDrops { registerForDraggedTypes([.fileURL]) }
            else { unregisterDraggedTypes() }
        }
    }

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFileDrops && !droppedFiles(sender).isEmpty ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsFileDrops && !droppedFiles(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsFileDrops else { return false }
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return false }
        // Quote each path, including spaces, apostrophes, and shell
        // metacharacters, without touching the system clipboard.
        let paths = ArgumentText.format(files.map(\.path)) + " "
        if let pasteHandler {
            // The controller's engine adapter applies bracketed paste and its
            // input gate, so a disconnected terminal never queues the drop.
            pasteHandler(paths)
        } else {
            let paste = getTerminal().bracketedPasteMode
                ? "\u{1b}[200~" + paths + "\u{1b}[201~" : paths
            send(txt: paste)
        }
        window?.makeFirstResponder(self)
        return true
    }
    /// Receives dropped file paths as pasted text. Set by the owning controller
    /// so drops are encoded and gated by its terminal engine adapter.
    var pasteHandler: ((String) -> Void)?
    /// Mirrors the engine adapter's input gate for the keys this view sends on
    /// its own (`sendWordNavigation`), which bypass SwiftTerm's delegate.
    var inputEnabled = true
    /// Set when a tab change asks for keyboard focus before the view is shown.
    var focusesWhenAttached = false
    /// Option-Arrow and Option-Delete as Terminal.app sends them. Without the
    /// kitty keyboard protocol, SwiftTerm encodes these as CSI modifier
    /// sequences (`ESC [1;3D`), which shells and CLIs leave unbound; the
    /// classic `ESC b`, `ESC f`, and `ESC DEL` move and delete by word everywhere.
    /// SwiftTerm's `keyDown` is not overridable, so the window's key monitor
    /// asks first. Returns true when the key was consumed.
    func sendWordNavigation(_ event: NSEvent) -> Bool {
        guard inputEnabled, optionAsMetaKey, terminal?.keyboardEnhancementFlags.isEmpty == true,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: send(txt: "\u{1b}b")
        case NSRightArrowFunctionKey: send(txt: "\u{1b}f")
        case NSDeleteCharacter: send(txt: "\u{1b}\u{7f}")
        default: return false
        }
        return true
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func isAccessibilityEnabled() -> Bool { true }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { window?.makeFirstResponder(self) }
    }
    override func accessibilityValue() -> Any? {
        guard terminal != nil else { return "" }
        // Reading accessibility content must not serialize the entire retained
        // scrollback. Expose the currently displayed rows, including scrolled
        // history, with wide-character continuation cells omitted.
        let terminal = getTerminal()
        return (0..<terminal.rows).compactMap {
            terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
                .replacingOccurrences(of: "\0", with: " ")
        }.joined(separator: "\n")
    }
    override func accessibilitySelectedText() -> String? { getSelection() }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == NSSelectorFromString("setAccessibilityValue:") || selector == NSSelectorFromString("setAccessibilitySelectedText:") { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applyAppearance()
        guard focusesWhenAttached else { return }
        focusesWhenAttached = false
        // SwiftUI is still installing this view; take focus once it settles.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
    func applyAppearance() {
        // AppKit can notify a view before TerminalView has finished its setup.
        guard terminal != nil, appliedAppearance != effectiveAppearance.name else { return }
        appliedAppearance = effectiveAppearance.name
        effectiveAppearance.performAsCurrentDrawingAppearance {
            configureNativeColors()
            caretColor = .textColor
            caretTextColor = .textBackgroundColor
        }
    }
}
