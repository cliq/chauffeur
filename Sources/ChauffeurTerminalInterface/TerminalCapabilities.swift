/// Features a terminal engine adapter may support. Used to gate app functionality that
/// depends on an engine capability without the app knowing which engine is in use.
public struct TerminalCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let selection = TerminalCapabilities(rawValue: 1 << 0)
    public static let clipboardCopy = TerminalCapabilities(rawValue: 1 << 1)
    public static let links = TerminalCapabilities(rawValue: 1 << 2)
    public static let bell = TerminalCapabilities(rawValue: 1 << 3)
    public static let mouseReporting = TerminalCapabilities(rawValue: 1 << 4)
    public static let title = TerminalCapabilities(rawValue: 1 << 5)
    public static let bracketedPaste = TerminalCapabilities(rawValue: 1 << 6)
    public static let scrollback = TerminalCapabilities(rawValue: 1 << 7)
    public static let search = TerminalCapabilities(rawValue: 1 << 8)

    /// What every production adapter must provide for the app to function.
    public static let required: TerminalCapabilities = [.selection, .clipboardCopy, .bracketedPaste, .scrollback]

    public func missingRequired() -> TerminalCapabilities {
        Self.required.subtracting(self)
    }
}
