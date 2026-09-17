/// Visual configuration for a terminal view, independent of the rendering engine.
public struct TerminalAppearance: Equatable, Sendable {
    /// `nil` selects the system monospaced font.
    public var fontName: String?
    public var fontSize: Double
    public var scrollbackLines: Int
    public var followsSystemColors: Bool

    public init(
        fontName: String? = nil,
        fontSize: Double = 13,
        scrollbackLines: Int = 10_000,
        followsSystemColors: Bool = true
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.scrollbackLines = scrollbackLines
        self.followsSystemColors = followsSystemColors
    }

    public static let `default` = TerminalAppearance()
}
