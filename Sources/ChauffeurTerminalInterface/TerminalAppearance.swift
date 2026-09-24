/// Visual configuration for a terminal view, independent of the rendering engine.
public struct TerminalAppearance: Equatable, Sendable {
    /// `nil` selects the engine's default monospaced font.
    public var fontName: String?
    public var fontSize: Double
    public var scrollbackLines: Int
    /// Default colors come from the system for any appearance without a theme.
    public var followsSystemColors: Bool
    /// Colors used while the system is in light or dark mode; `nil` keeps the system colors for
    /// that mode.
    public var lightColors: TerminalColorTheme?
    public var darkColors: TerminalColorTheme?

    public init(
        fontName: String? = nil,
        fontSize: Double = 13,
        scrollbackLines: Int = 10_000,
        followsSystemColors: Bool = true,
        lightColors: TerminalColorTheme? = nil,
        darkColors: TerminalColorTheme? = nil
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.scrollbackLines = scrollbackLines
        self.followsSystemColors = followsSystemColors
        self.lightColors = lightColors
        self.darkColors = darkColors
    }

    public static let `default` = TerminalAppearance()
}
