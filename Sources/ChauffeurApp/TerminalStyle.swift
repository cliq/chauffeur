import AppKit
import ChauffeurTerminalInterface

/// Where one appearance mode's terminal colors come from.
enum TerminalColorChoice: Equatable {
    /// The system text colors with the basic ANSI palette.
    case system
    /// A `TerminalThemeCatalog` theme, by name.
    case named(String)
    /// Colors edited in Settings. Only the active custom palette is kept; there is no library
    /// of saved custom themes.
    case custom(TerminalColorTheme)

    static let customTag = "\u{0}custom"

    /// The value a picker selects: `nil` for System, a theme name, or `customTag`.
    var tag: String? {
        switch self {
        case .system: nil
        case .named(let name): name
        case .custom: Self.customTag
        }
    }
}

/// The default look of every terminal view, chosen in Settings: font and color themes.
/// Per-terminal zoom (View ▸ Bigger and Smaller) is applied on top of it and never saved.
struct TerminalStyle: Equatable {
    /// A font family name, or `nil` for the terminal engine's built-in font.
    var fontFamily: String?
    var fontSize: Double
    var light: TerminalColorChoice
    var dark: TerminalColorChoice

    static let `default` = TerminalStyle(fontFamily: nil, fontSize: 13, light: .system, dark: .system)
    static let fontSizes: ClosedRange<Double> = 8...32

    init(fontFamily: String?, fontSize: Double, light: TerminalColorChoice, dark: TerminalColorChoice) {
        self.fontFamily = fontFamily
        self.fontSize = min(max(fontSize, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
        self.light = light
        self.dark = dark
    }

    func choice(dark: Bool) -> TerminalColorChoice { dark ? self.dark : light }

    /// The colors to hand the engine, or `nil` for the system colors.
    func appearanceColors(dark: Bool) -> TerminalColorTheme? {
        switch choice(dark: dark) {
        case .system: nil
        case .named(let name): TerminalThemeCatalog.theme(named: name)
        case .custom(let theme): theme
        }
    }

    /// The colors shown for a mode, with System resolved, for previews and the editor.
    @MainActor
    func colors(dark: Bool) -> TerminalColorTheme {
        appearanceColors(dark: dark) ?? .system(dark: dark)
    }

    /// Selects a picker tag. Choosing Custom again keeps the current custom colors, or starts
    /// them from what the mode showed.
    @MainActor
    mutating func select(tag: String?, dark: Bool) {
        let next: TerminalColorChoice
        switch tag {
        case nil: next = .system
        case TerminalColorChoice.customTag?:
            if case .custom = choice(dark: dark) { return }
            var theme = colors(dark: dark); theme.name = "Custom"
            next = .custom(theme)
        case let name?: next = .named(name)
        }
        if dark { self.dark = next } else { light = next }
    }

    /// Edits one mode's colors, turning its choice into Custom.
    @MainActor
    mutating func editColors(dark: Bool, _ edit: (inout TerminalColorTheme) -> Void) {
        var theme = colors(dark: dark)
        theme.name = "Custom"
        edit(&theme)
        if dark { self.dark = .custom(theme) } else { light = .custom(theme) }
    }

    func appearance(scrollback: Int) -> TerminalAppearance {
        TerminalAppearance(fontName: fontFamily, fontSize: fontSize, scrollbackLines: scrollback, followsSystemColors: true,
                           lightColors: appearanceColors(dark: false), darkColors: appearanceColors(dark: true))
    }

    // MARK: Persistence

    private static let fontFamilyKey = "terminalFontFamily"
    private static let fontSizeKey = "terminalFontSize"
    private static func themeKey(dark: Bool) -> String { dark ? "terminalDarkTheme" : "terminalLightTheme" }
    private static func customKey(dark: Bool) -> String { dark ? "terminalDarkCustomColors" : "terminalLightCustomColors" }

    init(preferences: UserDefaults) {
        let size = preferences.double(forKey: Self.fontSizeKey)
        func choice(dark: Bool) -> TerminalColorChoice {
            switch preferences.string(forKey: Self.themeKey(dark: dark)) {
            case TerminalColorChoice.customTag?:
                guard let data = preferences.data(forKey: Self.customKey(dark: dark)),
                      let theme = try? JSONDecoder().decode(TerminalColorTheme.self, from: data) else { return .system }
                return .custom(theme)
            case let name?:
                // A theme that left the catalog falls back to the system colors.
                return TerminalThemeCatalog.theme(named: name) == nil ? .system : .named(name)
            case nil:
                return .system
            }
        }
        self.init(fontFamily: preferences.string(forKey: Self.fontFamilyKey), fontSize: size > 0 ? size : Self.default.fontSize,
                  light: choice(dark: false), dark: choice(dark: true))
    }

    func save(to preferences: UserDefaults) {
        preferences.set(fontFamily, forKey: Self.fontFamilyKey)
        preferences.set(fontSize, forKey: Self.fontSizeKey)
        for dark in [false, true] {
            let choice = choice(dark: dark)
            preferences.set(choice.tag, forKey: Self.themeKey(dark: dark))
            if case .custom(let theme) = choice {
                preferences.set(try? JSONEncoder().encode(theme), forKey: Self.customKey(dark: dark))
            } else {
                preferences.removeObject(forKey: Self.customKey(dark: dark))
            }
        }
    }

    /// Installed fixed-pitch font families, sorted for a picker.
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        let families = (manager.availableFontNames(with: .fixedPitchFontMask) ?? []).compactMap { NSFont(name: $0, size: 12)?.familyName }
        return Set(families).filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
