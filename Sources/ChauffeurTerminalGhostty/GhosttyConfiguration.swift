#if os(macOS)
import AppKit
import ChauffeurTerminalInterface

/// The complete Ghostty configuration for one kind of terminal. Chauffeur generates every line:
/// the user's `~/.config/ghostty` is never read, so a personal config cannot rebind the app's
/// shortcuts or break the host-managed terminals.
struct GhosttyConfiguration: Hashable, Sendable {
    var fontName: String?
    var fontSize: Double
    var scrollbackLines: Int
    /// Light and dark palettes resolved from the system colors, or `nil` for Ghostty's defaults.
    var colors: GhosttyColorPair?

    @MainActor
    init(_ appearance: TerminalAppearance) {
        fontName = appearance.fontName
        fontSize = appearance.fontSize
        scrollbackLines = appearance.scrollbackLines
        let light = appearance.lightColors, dark = appearance.darkColors
        colors = appearance.followsSystemColors || light != nil || dark != nil
            ? GhosttyColorPair(light: light.map(GhosttyPalette.init) ?? .resolved(in: .aqua), dark: dark.map(GhosttyPalette.init) ?? .resolved(in: .darkAqua))
            : nil
    }

    /// Ghostty limits scrollback in bytes, not lines. A row costs its cells (8 bytes each) plus
    /// page metadata; budget for wide rows so the line count is a floor, not a ceiling.
    static let bytesPerScrollbackLine = 2_048

    /// Renders the config file with the colors for one appearance. Colors are written out
    /// explicitly rather than through `theme = light:…,dark:…`: the view swaps configs when its
    /// appearance changes, which does not depend on Ghostty rebuilding conditional themes.
    func rendered(dark: Bool) -> String {
        var lines = [
            "font-size = \(Self.literal(fontSize))",
            "scrollback-limit = \(max(1, scrollbackLines) * Self.bytesPerScrollbackLine)",
            // The app's menu owns Copy, Paste, Select All and Find; nothing Ghostty binds by
            // default may shadow a Chauffeur shortcut.
            "keybind = clear",
            // Option-Arrow and Option-Delete as Terminal.app sends them: shells and CLIs leave
            // the CSI modifier forms (ESC [1;3D) unbound, the classic forms work everywhere.
            "keybind = alt+left=esc:b",
            "keybind = alt+right=esc:f",
            "keybind = alt+backspace=text:\\x1b\\x7f",
            // The app menu's Bigger item is Cmd-+; accept the unshifted key too, as Terminal.app does.
            "keybind = super+equal=increase_font_size:1",
            "macos-option-as-alt = true",
            // Programs may set the clipboard (OSC 52) through the adapter, never read it.
            "clipboard-read = deny",
            "clipboard-write = allow",
            "clipboard-paste-protection = false",
            "copy-on-select = false",
            "confirm-close-surface = false",
            "mouse-hide-while-typing = false",
            "cursor-style = block",
            "cursor-style-blink = true",
            "window-padding-x = 4",
            "window-padding-y = 2",
            "window-padding-balance = true",
            "shell-integration = none",
        ]
        if let fontName, !fontName.isEmpty {
            lines.insert("font-family = \(fontName)", at: 0)
        }
        if let colors {
            lines += (dark ? colors.dark : colors.light).configLines
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Ghostty parses numbers with `.` and ASCII digits whatever the user's locale.
    static func literal(_ value: Double) -> String {
        value.formatted(FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
            .precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// Default foreground/background/cursor/selection colors for each appearance, as hex strings.
struct GhosttyColorPair: Hashable, Sendable {
    var light: GhosttyPalette
    var dark: GhosttyPalette

    /// The same colors the SwiftTerm views took from `configureNativeColors()`.
    @MainActor
    static func system() -> GhosttyColorPair {
        GhosttyColorPair(light: .resolved(in: .aqua), dark: .resolved(in: .darkAqua))
    }
}

struct GhosttyPalette: Hashable, Sendable {
    var background: String
    var foreground: String
    var selectionBackground: String
    var cursor: String?
    var cursorText: String?
    var selectionForeground: String?
    var ansi = TerminalThemeCatalog.basicANSI

    init(background: String, foreground: String, selectionBackground: String) {
        self.background = background
        self.foreground = foreground
        self.selectionBackground = selectionBackground
    }

    init(_ theme: TerminalColorTheme) {
        background = theme.background
        foreground = theme.foreground
        selectionBackground = theme.selectionBackground ?? theme.foreground
        cursor = theme.cursor
        cursorText = theme.cursorText
        selectionForeground = theme.selectionForeground
        ansi = theme.palette.count == 16 ? theme.palette : TerminalThemeCatalog.basicANSI
    }

    @MainActor
    static func resolved(in name: NSAppearance.Name) -> GhosttyPalette {
        GhosttyPalette(TerminalColorTheme.system(dark: name == .darkAqua))
    }

    var configLines: [String] {
        [
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(cursor ?? foreground)",
            "cursor-text = \(cursorText ?? background)",
            "selection-background = \(selectionBackground)",
            "selection-foreground = \(selectionForeground ?? foreground)",
        ] + ansi.enumerated().map { "palette = \($0.offset)=\($0.element)" }
    }
}
#endif
