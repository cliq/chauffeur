// SwiftTermAdapter
//
// The only module outside the desktop app that may `import SwiftTerm`. Everything else talks
// to the terminal through `TerminalEngineAdapter` so the engine stays replaceable.
//
// This target has no test target (SwiftTerm needs a UI framework at runtime). Verification is
// by compiling for macOS and the iOS simulator plus the manual checks below.
//
// Manual checks (run against a live tmux attachment on both platforms):
//  1. Typing on the hardware/software keyboard reaches `TerminalEngineAdapterDelegate
//     .terminal(_:didGenerateInput:)` exactly once per key and nothing is echoed locally by the
//     adapter; the echo comes back from the remote process through `feed(_:)`.
//  2. `sendKey(.up)` sends `ESC [ A` in a shell and `ESC O A` inside an application-cursor
//     program (`less`, `vim`); `sendKey(.backspace)` sends 0x7f unless the view's
//     `backspaceSendsControlH` is on.
//  3. `paste("a\nb")` inside a bracketed-paste program (`zsh`, `vim`) arrives wrapped in
//     `ESC [ 200~` ... `ESC [ 201~` with the newline preserved; in `cat` it arrives as `a\rb`.
//  4. `setInputEnabled(false)`: typing, `sendKey`, and `paste` produce no delegate calls, and
//     re-enabling does NOT replay anything typed while disabled.
//  5. Rotating the phone / resizing the window calls `didChangeCellSize` with cols and rows
//     >= 2 and matches `cellSize`.
//  6. `printf '\e]0;title\a'` triggers `didChangeTitle("title")`; `printf '\a'` triggers
//     `terminalDidRingBell`; `printf '\e]52;c;aGVsbG8=\a'` triggers `didCopyToClipboard("hello")`
//     and the pasteboard is untouched until the app writes to it.
//  7. Tapping / clicking `https://example.com` calls `didRequestOpenLink`; a `file://` or custom
//     scheme link does not (macOS must not open it through SwiftTerm's default handler either).
//  8. `reset()` blanks the screen and scrollback; the following tmux redraw repaints it.
//  9. On iOS the keyboard shows no SwiftTerm accessory bar, and autocorrection, smart quotes and
//     capitalization stay off.
// 10. `selectedText()` returns the selection while one is active and `nil` after it clears.
// 11. `TerminalAdapterConformance.check(adapter)` returns no problems.

import Foundation
@preconcurrency import SwiftTerm
import ChauffeurTerminalInterface
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
#elseif canImport(AppKit)
import AppKit
typealias PlatformFont = NSFont
#endif

/// `TerminalEngineAdapter` backed by SwiftTerm's platform `TerminalView`.
///
/// Byte I/O flows only through the adapter: output arrives via `feed(_:)` and input leaves via
/// `TerminalEngineAdapterDelegate.terminal(_:didGenerateInput:)`. The adapter never echoes input
/// into the view; the remote process is responsible for echo.
@MainActor
public final class SwiftTermAdapter: NSObject, TerminalEngineAdapter {
    /// The SwiftTerm view this adapter drives.
    ///
    /// Exposed ONLY so the desktop can reach engine-specific features that have no engine-neutral
    /// contract yet (history find through `performTextFinderAction`, accessibility). App code must
    /// not use it for byte I/O: never call `feed`, `send`, or set `terminalDelegate` on it. Use
    /// `feed(_:)`, `sendKey(_:)`, `paste(_:)` and the adapter delegate instead, or the input
    /// gate and the delegate mapping are bypassed.
    public let view: TerminalView

    public weak var delegate: (any TerminalEngineAdapterDelegate)?

    public let capabilities: TerminalCapabilities = {
        var capabilities: TerminalCapabilities = [
            .selection, .clipboardCopy, .links, .bell, .title, .bracketedPaste, .scrollback
        ]
        #if canImport(AppKit)
        // NSTextFinder-based history search only exists in the macOS view.
        capabilities.insert(.search)
        #endif
        return capabilities
    }()

    /// Read live from the engine so key and paste encoding follow mode changes made by the
    /// remote program (e.g. `vim` turning application cursor keys on).
    public var modes: TerminalModes {
        let terminal = view.getTerminal()
        return TerminalModes(
            applicationCursor: terminal.applicationCursor,
            bracketedPaste: terminal.bracketedPasteMode,
            backspaceSendsControlH: view.backspaceSendsControlH
        )
    }

    public var cellSize: TerminalCellSize {
        let terminal = view.getTerminal()
        return TerminalCellSize(cols: max(1, terminal.cols), rows: max(1, terminal.rows))
    }

    public private(set) var isInputEnabled = true

    /// Creates and owns a platform `TerminalView`.
    ///
    /// On iOS this also turns off autocorrection and smart punctuation, keeps the default
    /// keyboard so Unicode input works, and installs NO SwiftTerm accessory bar: the app supplies
    /// its own key bar through `sendKey(_:)`.
    public convenience init(appearance: TerminalAppearance = .default) {
        #if canImport(UIKit)
        let view = WheelScrollingTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), font: nil)
        #else
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        #endif
        self.init(view: view, appearance: appearance)
    }

    /// Wraps a SwiftTerm view supplied by the host app (the desktop passes its themed subclass).
    /// The adapter becomes the view's `terminalDelegate`.
    public init(view: TerminalView, appearance: TerminalAppearance = .default) {
        self.view = view
        super.init()
        view.terminalDelegate = self
        configurePlatformInput()
        configure(appearance)
    }

    // MARK: TerminalEngineAdapter

    public func makeView() -> PlatformView {
        view
    }

    public func configure(_ appearance: TerminalAppearance) {
        view.font = Self.font(for: appearance)
        view.changeScrollback(appearance.scrollbackLines)
        #if canImport(AppKit)
        if appearance.followsSystemColors {
            view.configureNativeColors()
        }
        #endif
    }

    public func feed(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        view.feed(byteArray: ArraySlice([UInt8](bytes)))
    }

    /// Full reset (`ESC c`) followed by a scrollback clear. `ESC c` resets modes, attributes and
    /// the visible screen; SwiftTerm exposes `clearScrollback()` for the history. The screen
    /// content itself comes back with the redraw tmux sends after a fresh attachment.
    public func reset() {
        view.feed(text: "\u{1b}c")
        view.clearScrollback()
    }

    public func sendKey(_ action: TerminalKeyAction) {
        emit(TerminalKeyEncoder.encode(action, modes: modes))
    }

    public func paste(_ text: String) {
        emit(TerminalKeyEncoder.encodePaste(text, modes: modes))
    }

    /// When disabled, input from the engine (typing) and from `sendKey`/`paste` is dropped, never
    /// queued: the app must not see a burst of stale keystrokes when input comes back.
    public func setInputEnabled(_ enabled: Bool) {
        isInputEnabled = enabled
    }

    public func focus() {
        #if canImport(UIKit)
        _ = view.becomeFirstResponder()
        #elseif canImport(AppKit)
        view.window?.makeFirstResponder(view)
        #endif
    }

    public func selectedText() -> String? {
        guard view.selectionActive else { return nil }
        return view.getSelection()
    }

    /// Detaches the adapter from the view and the app. `view` stays alive as long as the adapter
    /// does (it is immutable), so the app releases both by dropping the adapter.
    public func dispose() {
        view.terminalDelegate = nil
        view.removeFromSuperview()
        delegate = nil
    }

    // MARK: Input routing

    /// The single exit for generated input. Gated by `isInputEnabled`; never fed back into the
    /// view because local echo is the remote process's job.
    func emit(_ data: Data) {
        guard isInputEnabled, !data.isEmpty else { return }
        delegate?.terminal(self, didGenerateInput: data)
    }

    // MARK: Platform setup

    private func configurePlatformInput() {
        #if canImport(UIKit)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        // `keyboardType` is get-only in SwiftTerm 1.20 and already reports `.default` (not
        // `.asciiCapable`), so Unicode input works without any change here.
        view.keyboardAppearance = .default
        // The app draws its own key bar and routes it through `sendKey(_:)`.
        view.inputAccessoryView = nil
        // tmux runs with mouse mode on, and SwiftTerm would forward a finger pan to it as a mouse
        // drag instead of scrolling. Keep panning local: it scrolls the buffer, and inside a
        // full-screen program it sends cursor keys.
        view.allowMouseReporting = false
        #endif
    }

    private static func font(for appearance: TerminalAppearance) -> PlatformFont {
        let size = CGFloat(appearance.fontSize)
        if let name = appearance.fontName, let named = PlatformFont(name: name, size: size) {
            return named
        }
        return PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
