import AppKit
@preconcurrency import SwiftTerm

/// Updates default terminal colors without replacing the terminal or its buffer.
final class ThemedTerminalView: TerminalView {
    private var appliedAppearance: NSAppearance.Name?
    /// Set when a tab change asks for keyboard focus before the view is shown.
    var focusesWhenAttached = false
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
