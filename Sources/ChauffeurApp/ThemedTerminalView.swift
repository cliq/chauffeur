import AppKit
@preconcurrency import SwiftTerm

/// Updates default terminal colors without replacing the terminal or its buffer.
final class ThemedTerminalView: TerminalView {
    private var appliedAppearance: NSAppearance.Name?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { applyAppearance() }
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
