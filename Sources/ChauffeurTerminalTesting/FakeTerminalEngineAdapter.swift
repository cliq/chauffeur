import Foundation
import ChauffeurTerminalInterface

/// A `TerminalEngineAdapter` with no rendering engine behind it, for tests and previews.
@MainActor
public final class FakeTerminalEngineAdapter: TerminalEngineAdapter {
    public weak var delegate: (any TerminalEngineAdapterDelegate)?
    public var capabilities: TerminalCapabilities = .required.union([.bell, .title])
    public var modes: TerminalModes = TerminalModes()
    public var cellSize: TerminalCellSize = TerminalCellSize(cols: 80, rows: 24)
    public private(set) var isInputEnabled: Bool = true
    public var selection: String?

    public private(set) var fed: [Data] = []
    public private(set) var feedCount = 0
    public private(set) var resetCount = 0
    public private(set) var disposed = false
    public private(set) var configuredAppearance: TerminalAppearance?
    public private(set) var sentKeys: [TerminalKeyAction] = []
    public private(set) var generatedInput: [Data] = []
    public private(set) var focusCount = 0

    private var view: PlatformView?

    public init() {}

    public func makeView() -> PlatformView {
        if let view {
            return view
        }
        let view = PlatformView()
        self.view = view
        return view
    }

    public func configure(_ appearance: TerminalAppearance) {
        configuredAppearance = appearance
    }

    public func feed(_ bytes: Data) {
        fed.append(bytes)
        feedCount += 1
    }

    public func reset() {
        resetCount += 1
        fed.removeAll()
    }

    public func sendKey(_ action: TerminalKeyAction) {
        sentKeys.append(action)
        emitInput(TerminalKeyEncoder.encode(action, modes: modes))
    }

    public func paste(_ text: String) {
        emitInput(TerminalKeyEncoder.encodePaste(text, modes: modes))
    }

    public func setInputEnabled(_ enabled: Bool) {
        isInputEnabled = enabled
    }

    public func focus() {
        focusCount += 1
    }

    public func selectedText() -> String? {
        selection
    }

    public func dispose() {
        disposed = true
    }

    /// Routes generated input through `isInputEnabled`, dropping it (never queuing) when disabled.
    private func emitInput(_ data: Data) {
        guard isInputEnabled else { return }
        guard !data.isEmpty else { return }
        generatedInput.append(data)
        delegate?.terminal(self, didGenerateInput: data)
    }

    // MARK: - Test drivers

    public func simulateTypedInput(_ data: Data) {
        emitInput(data)
    }

    public func simulateResize(cols: Int, rows: Int) {
        cellSize = TerminalCellSize(cols: cols, rows: rows)
        delegate?.terminal(self, didChangeCellSize: cellSize)
    }

    public func simulateTitle(_ title: String) {
        delegate?.terminal(self, didChangeTitle: title)
    }

    public func simulateBell() {
        delegate?.terminalDidRingBell(self)
    }

    /// A naive accumulation of fed bytes decoded as UTF-8 with escape sequences stripped
    /// (CSI `ESC [ ... final-byte` and single `ESC x`), enough for tests to assert visible text.
    public var screenText: String {
        var result = ""
        for chunk in fed {
            result += Self.stripEscapeSequences(chunk)
        }
        return result
    }

    private static func stripEscapeSequences(_ data: Data) -> String {
        let bytes = Array(data)
        var stripped: [UInt8] = []
        stripped.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x1b else {
                stripped.append(byte)
                index += 1
                continue
            }
            let next = index + 1 < bytes.count ? bytes[index + 1] : nil
            if next == UInt8(ascii: "[") {
                var cursor = index + 2
                while cursor < bytes.count, !(0x40...0x7e).contains(bytes[cursor]) {
                    cursor += 1
                }
                // Consume the final byte too, if present.
                index = min(cursor + 1, bytes.count)
            } else if let next {
                // Single two-byte escape, e.g. `ESC c`.
                _ = next
                index += 2
            } else {
                index += 1
            }
        }
        return String(decoding: stripped, as: UTF8.self)
    }
}
