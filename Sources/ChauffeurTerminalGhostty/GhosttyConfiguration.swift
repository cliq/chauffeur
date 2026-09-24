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
        colors = appearance.followsSystemColors ? .system() : nil
    }

    /// Ghostty limits scrollback in bytes, not lines. A row costs its cells (8 bytes each) plus
    /// page metadata; budget for wide rows so the line count is a floor, not a ceiling.
    static let bytesPerScrollbackLine = 2_048

    /// Renders the config file, pointing `theme` at `themeFiles` when colors are set.
    func rendered(themeFiles: (light: URL, dark: URL)?) -> String {
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
        if let themeFiles {
            lines.append("theme = light:\(themeFiles.light.path),dark:\(themeFiles.dark.path)")
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

    @MainActor
    static func resolved(in name: NSAppearance.Name) -> GhosttyPalette {
        var palette = GhosttyPalette(background: "#ffffff", foreground: "#000000", selectionBackground: "#b4d5fe")
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            palette = GhosttyPalette(
                background: NSColor.textBackgroundColor.ghosttyHex,
                foreground: NSColor.textColor.ghosttyHex,
                selectionBackground: NSColor.selectedTextBackgroundColor.ghosttyHex
            )
        }
        return palette
    }

    /// Terminal.app's "Basic" ANSI colors, which read on both light and dark backgrounds.
    static let ansi = [
        "#000000", "#990000", "#00a600", "#999900", "#0000b2", "#b200b2", "#00a6b2", "#bfbfbf",
        "#666666", "#e50000", "#00d900", "#e5e500", "#0000ff", "#e500e5", "#00e5e5", "#e5e5e5",
    ]

    var themeFile: String {
        var lines = [
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(foreground)",
            "cursor-text = \(background)",
            "selection-background = \(selectionBackground)",
            "selection-foreground = \(foreground)",
        ]
        lines += Self.ansi.enumerated().map { "palette = \($0.offset)=\($0.element)" }
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension NSColor {
    var ghosttyHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
#endif
