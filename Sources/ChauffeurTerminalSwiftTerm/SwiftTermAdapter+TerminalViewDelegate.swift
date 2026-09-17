import Foundation
@preconcurrency import SwiftTerm
import ChauffeurTerminalInterface

/// Maps SwiftTerm's view callbacks onto the engine-neutral delegate.
///
/// `TerminalViewDelegate` is declared without actor isolation in SwiftTerm (Swift 5 language
/// mode), while `TerminalView` only ever calls it on the main thread. The `@preconcurrency`
/// conformance lets the main-actor adapter satisfy it, matching how the desktop app conforms.
extension SwiftTermAdapter: @preconcurrency TerminalViewDelegate {
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        emit(Data(data))
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm reports transient 1x1 (or smaller) sizes while a view is being laid out.
        guard newCols >= 2, newRows >= 2 else { return }
        delegate?.terminal(self, didChangeCellSize: TerminalCellSize(cols: newCols, rows: newRows))
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        delegate?.terminal(self, didChangeTitle: title)
    }

    public func bell(source: TerminalView) {
        delegate?.terminalDidRingBell(self)
    }

    /// OSC 52 copy request. The APP decides whether to write to the pasteboard; the adapter never
    /// touches `UIPasteboard`/`NSPasteboard`.
    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        delegate?.terminal(self, didCopyToClipboard: text)
    }

    /// OSC 52 read request: always denied.
    public func clipboardRead(source: TerminalView) -> Data? {
        nil
    }

    /// Only web and mail links are surfaced. Implementing this also replaces SwiftTerm's macOS
    /// default, which would otherwise open any scheme through `NSWorkspace`.
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return }
        delegate?.terminal(self, didRequestOpenLink: link)
    }

    public func scrolled(source: TerminalView, position: Double) {}

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
