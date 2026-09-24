// GhosttyTerminalAdapter
//
// The desktop's `TerminalEngineAdapter`, backed by libghostty (libghostty-spm's prebuilt
// GhosttyKit) with host-managed I/O: the runtime owns the process and the tmux attachment, this
// adapter feeds its output to Ghostty and hands back what Ghostty generates. The only module that
// may `import GhosttyKit`.
//
// Manual checks (against a live tmux attachment):
//  1. Typing reaches `didGenerateInput` exactly once per key with no local echo; the echo comes
//     back through `feed(_:)`.
//  2. Cursor keys and `sendKey(.up)` send `ESC [ A` in a shell and `ESC O A` in `less`/`vim`.
//  3. Pasting "a\nb" inside `zsh`/`vim` arrives inside `ESC [ 200~` ... `ESC [ 201~`.
//  4. `setInputEnabled(false)`: typing, `sendKey`, `paste` and drops produce nothing, and
//     re-enabling does not replay them.
//  5. Resizing the window reports `didChangeCellSize` once the grid changed, cols/rows >= 2.
//  6. `printf '\e]0;title\a'` → `didChangeTitle`; `printf '\a'` → `terminalDidRingBell`;
//     `printf '\e]52;c;aGVsbG8=\a'` → `didCopyToClipboard("hello")`, pasteboard untouched.
//  7. Cmd-clicking `https://example.com` → `didRequestOpenLink`; other schemes are dropped.
//  8. `reset()` blanks screen and scrollback; the tmux redraw repaints it.
//  9. Option-Left/Right/Delete move and delete by word; Cmd shortcuts reach the app menu.
// 10. Japanese IME composition shows inline and commits once; wide glyphs align.
// 11. `TerminalAdapterConformance.check(adapter)` returns no problems.

#if os(macOS)
import AppKit
import GhosttyKit
import ChauffeurTerminalInterface

@MainActor
public final class GhosttyTerminalAdapter: TerminalEngineAdapter, GhosttySurfaceHost {
    public weak var delegate: (any TerminalEngineAdapterDelegate)?
    public let capabilities: TerminalCapabilities = [
        .selection, .clipboardCopy, .links, .bell, .mouseReporting, .title, .bracketedPaste, .scrollback, .search,
    ]
    /// The last grid Ghostty applied; a default until the view first lays out in a window.
    public private(set) var cellSize = TerminalCellSize(cols: 80, rows: 24)
    public private(set) var isInputEnabled = true
    private let view: GhosttySurfaceView
    private var searchTotal: Int?
    private var searchSelected: Int?

    /// - Parameter acceptsFileDrops: whether files dropped on the view paste their quoted paths.
    public init(appearance: TerminalAppearance = .default, acceptsFileDrops: Bool = false) {
        view = GhosttySurfaceView(configuration: GhosttyConfiguration(appearance))
        view.acceptsFileDrops = acceptsFileDrops
        view.host = self
    }

    /// Ghostty's config diagnostics for this adapter's configuration (empty when accepted in
    /// full). Creates the shared runtime if no surface did yet.
    public var configurationDiagnostics: [String] {
        guard let runtime = GhosttyRuntime.acquire(view.configuration) else { return ["Ghostty could not load the configuration"] }
        defer { runtime.release() }
        return runtime.diagnostics
    }

    // MARK: TerminalEngineAdapter

    public func makeView() -> PlatformView { view }

    public func configure(_ appearance: TerminalAppearance) {
        view.reconfigure(GhosttyConfiguration(appearance))
    }

    public func feed(_ bytes: Data) {
        view.output.enqueue(bytes, replay: false)
    }

    /// History is parsed with Ghostty's query replies suppressed, so saved output can never
    /// answer on the terminal's behalf.
    public func replay(_ bytes: Data) {
        view.output.enqueue(bytes, replay: true)
    }

    /// Full reset (`ESC c`) and a scrollback erase (`ESC [3J`), queued behind earlier output so
    /// the redraw tmux sends after a fresh attachment lands on a blank terminal.
    public func reset() {
        view.output.discardPending()
        view.output.enqueue(Data("\u{1b}c\u{1b}[3J".utf8), replay: false)
    }

    public func sendKey(_ action: TerminalKeyAction) {
        guard isInputEnabled else { return }
        if let surface = view.surface, let press = GhosttyKeyPress(action) {
            press.send(to: surface)
        } else {
            // No surface yet, or a key with no US-keyboard equivalent: send the xterm bytes.
            emit(TerminalKeyEncoder.encode(action, modes: TerminalModes()))
        }
    }

    public func paste(_ text: String) {
        guard isInputEnabled, !text.isEmpty else { return }
        if let surface = view.surface {
            text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        } else {
            emit(TerminalKeyEncoder.encodePaste(text, modes: TerminalModes()))
        }
    }

    /// When disabled, everything Ghostty generates is dropped, never queued.
    public func setInputEnabled(_ enabled: Bool) {
        isInputEnabled = enabled
    }

    public func focus() {
        view.focus()
    }

    public func selectedText() -> String? {
        view.selectionText()
    }

    public func screenText(includingScrollback: Bool) -> String? {
        view.readText(includingScrollback: includingScrollback)
    }

    public func search(_ query: String) {
        guard !query.isEmpty else { endSearch(); return }
        view.performBindingAction("search:\(query)")
    }

    public func searchNext() { view.performBindingAction("navigate_search:next") }
    public func searchPrevious() { view.performBindingAction("navigate_search:previous") }

    public func endSearch() {
        view.performBindingAction("end_search")
        updateSearch(total: nil, selected: nil)
    }

    /// Frees the surface and detaches the view. The view stays alive as long as the adapter.
    public func dispose() {
        view.host = nil
        view.releaseRuntime()
        view.removeFromSuperview()
        delegate = nil
    }

    /// Waits until everything fed so far has been parsed. For tests and the Debug probe.
    public func waitForPendingOutput() {
        view.output.waitUntilIdle(ticking: view.runtime)
    }

    // MARK: GhosttySurfaceHost

    func surfaceDidGenerateInput(_ data: Data) {
        emit(data)
    }

    func surfaceDidResizeGrid(columns: Int, rows: Int) {
        guard columns >= 2, rows >= 2 else { return }
        let size = TerminalCellSize(cols: columns, rows: rows)
        guard size != cellSize else { return }
        cellSize = size
        delegate?.terminal(self, didChangeCellSize: size)
    }

    func surfaceDidReceive(_ event: GhosttySurfaceEvent) {
        switch event {
        case .title(let title):
            delegate?.terminal(self, didChangeTitle: title)
        case .bell:
            delegate?.terminalDidRingBell(self)
        case .openURL(let link):
            // Only web and mail links; Ghostty never opens anything itself.
            guard let scheme = URL(string: link)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
            delegate?.terminal(self, didRequestOpenLink: link)
        case .clipboardWrite(let text):
            delegate?.terminal(self, didCopyToClipboard: text)
        case .searchStarted:
            updateSearch(total: nil, selected: nil)
        case .searchEnded:
            updateSearch(total: nil, selected: nil)
        case .searchTotal(let total):
            updateSearch(total: total, selected: searchSelected)
        case .searchSelected(let selected):
            updateSearch(total: searchTotal, selected: selected.map { $0 + 1 })
        case .mouseShape:
            break
        }
    }

    func surfaceWantsToPaste(_ text: String) {
        paste(text)
    }

    // MARK: Input

    /// The single exit for generated input, gated by `isInputEnabled`.
    private func emit(_ data: Data) {
        guard isInputEnabled, !data.isEmpty else { return }
        delegate?.terminal(self, didGenerateInput: data)
    }

    private func updateSearch(total: Int?, selected: Int?) {
        guard total != searchTotal || selected != searchSelected else { return }
        searchTotal = total
        searchSelected = selected
        delegate?.terminal(self, didUpdateSearchTotal: total, selected: selected)
    }
}
#endif
