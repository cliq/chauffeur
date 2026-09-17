import Foundation

/// An engine-neutral terminal contract so the app's session/connection logic never touches
/// a specific rendering engine (SwiftTerm, Ghostty, ...) directly. The connection controller
/// feeds ordered output bytes in and receives generated input bytes and cell-size changes out.
@MainActor
public protocol TerminalEngineAdapter: AnyObject {
    var delegate: (any TerminalEngineAdapterDelegate)? { get set }
    var capabilities: TerminalCapabilities { get }
    /// Live engine modes, used for key/paste encoding.
    var modes: TerminalModes { get }
    var cellSize: TerminalCellSize { get }
    var isInputEnabled: Bool { get }

    /// Returns the same view instance every time; engine types must not leak through it.
    func makeView() -> PlatformView
    func configure(_ appearance: TerminalAppearance)
    /// Ordered output from the remote process.
    func feed(_ bytes: Data)
    /// Clears screen, scrollback, and modes before a fresh attachment (e.g. feed ESC c).
    func reset()
    /// Encodes with `TerminalKeyEncoder` using the current modes, then routes like typed input.
    func sendKey(_ action: TerminalKeyAction)
    func paste(_ text: String)
    /// When `false`, generated input is DROPPED (never queued) — the app must not replay keystrokes.
    func setInputEnabled(_ enabled: Bool)
    func focus()
    func selectedText() -> String?
    func dispose()
}

public struct TerminalCellSize: Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

@MainActor
public protocol TerminalEngineAdapterDelegate: AnyObject {
    func terminal(_ adapter: any TerminalEngineAdapter, didGenerateInput data: Data)
    func terminal(_ adapter: any TerminalEngineAdapter, didChangeCellSize size: TerminalCellSize)
    func terminal(_ adapter: any TerminalEngineAdapter, didChangeTitle title: String)
    func terminalDidRingBell(_ adapter: any TerminalEngineAdapter)
    func terminal(_ adapter: any TerminalEngineAdapter, didCopyToClipboard text: String)
    func terminal(_ adapter: any TerminalEngineAdapter, didRequestOpenLink link: String)
}

public extension TerminalEngineAdapterDelegate {
    func terminal(_ adapter: any TerminalEngineAdapter, didChangeTitle title: String) {}
    func terminalDidRingBell(_ adapter: any TerminalEngineAdapter) {}
    func terminal(_ adapter: any TerminalEngineAdapter, didCopyToClipboard text: String) {}
    func terminal(_ adapter: any TerminalEngineAdapter, didRequestOpenLink link: String) {}
}

/// Diagnostics that help catch adapter implementations that violate the contract.
public enum TerminalAdapterConformance {
    @MainActor
    public static func check(_ adapter: any TerminalEngineAdapter) -> [String] {
        var problems: [String] = []

        let missing = adapter.capabilities.missingRequired()
        if !missing.isEmpty {
            problems.append("Adapter is missing required capabilities: \(missing)")
        }

        let firstView = adapter.makeView()
        let secondView = adapter.makeView()
        if firstView !== secondView {
            problems.append("makeView() returned different instances on two calls")
        }

        return problems
    }
}
