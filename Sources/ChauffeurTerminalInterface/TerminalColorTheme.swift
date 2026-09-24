import Foundation

/// A named terminal color scheme: default colors plus the 16 ANSI colors, as `#rrggbb`.
public struct TerminalColorTheme: Hashable, Sendable, Identifiable, Codable {
    public var id: String { name }
    public var name: String
    public var background: String
    public var foreground: String
    public var cursor: String?
    public var cursorText: String?
    public var selectionBackground: String?
    public var selectionForeground: String?
    public var palette: [String]

    public init(name: String, background: String, foreground: String, cursor: String? = nil, cursorText: String? = nil,
                selectionBackground: String? = nil, selectionForeground: String? = nil, palette: [String]) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }

    /// Whether the background is dark (relative luminance below one half).
    public var isDark: Bool {
        let hex = background.drop { $0 == "#" }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return true }
        let (r, g, b) = (Double(value >> 16 & 0xff), Double(value >> 8 & 0xff), Double(value & 0xff))
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255 < 0.5
    }
}

/// A curated set of popular color schemes. Color data from iTerm2-Color-Schemes
/// (https://github.com/mbadolato/iTerm2-Color-Schemes, MIT), as packaged by libghostty-spm's
/// GhosttyTheme (MIT).
public enum TerminalThemeCatalog {
    public static func theme(named name: String?) -> TerminalColorTheme? {
        guard let name else { return nil }
        return all.first { $0.name == name }
    }

    public static let all: [TerminalColorTheme] = [
        TerminalColorTheme(name: "Apple System Colors", background: "#1e1e1e", foreground: "#ffffff", cursor: "#98989d", cursorText: "#ffffff", selectionBackground: "#3f638b", selectionForeground: "#ffffff",
                           palette: ["#1a1a1a", "#cc372e", "#26a439", "#cdac08", "#0869cb", "#9647bf", "#479ec2", "#98989d", "#464646", "#ff453a", "#32d74b", "#ffd60a", "#0a84ff", "#bf5af2", "#76d6ff", "#ffffff"]),
        TerminalColorTheme(name: "Apple System Colors Light", background: "#feffff", foreground: "#000000", cursor: "#98989d", cursorText: "#ffffff", selectionBackground: "#abd8ff", selectionForeground: "#000000",
                           palette: ["#1a1a1a", "#cc372e", "#26a439", "#cdac08", "#0869cb", "#9647bf", "#479ec2", "#98989d", "#464646", "#ff453a", "#32d74b", "#e5bc00", "#0a84ff", "#bf5af2", "#69c9f2", "#ffffff"]),
        TerminalColorTheme(name: "Atom One Dark", background: "#21252b", foreground: "#abb2bf", cursor: "#abb2bf", cursorText: "#21252b", selectionBackground: "#323844", selectionForeground: "#abb2bf",
                           palette: ["#21252b", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf", "#767676", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf"]),
        TerminalColorTheme(name: "Atom One Light", background: "#f9f9f9", foreground: "#2a2c33", cursor: "#bbbbbb", cursorText: "#ffffff", selectionBackground: "#ededed", selectionForeground: "#2a2c33",
                           palette: ["#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#950095", "#3f953a", "#bbbbbb", "#000000", "#de3e35", "#3f953a", "#d2b67c", "#2f5af3", "#a00095", "#3f953a", "#ffffff"]),
        TerminalColorTheme(name: "Ayu", background: "#0b0e14", foreground: "#bfbdb6", cursor: "#e6b450", cursorText: "#0b0e14", selectionBackground: "#409fff", selectionForeground: "#0b0e14",
                           palette: ["#11151c", "#ea6c73", "#7fd962", "#f9af4f", "#53bdfa", "#cda1fa", "#90e1c6", "#c7c7c7", "#686868", "#f07178", "#aad94c", "#ffb454", "#59c2ff", "#d2a6ff", "#95e6cb", "#ffffff"]),
        TerminalColorTheme(name: "Ayu Light", background: "#f8f9fa", foreground: "#5c6166", cursor: "#ffaa33", cursorText: "#f8f9fa", selectionBackground: "#035bd6", selectionForeground: "#f8f9fa",
                           palette: ["#000000", "#ea6c6d", "#6cbf43", "#eca944", "#3199e1", "#9e75c7", "#46ba94", "#bababa", "#686868", "#f07171", "#86b300", "#f2ae49", "#399ee6", "#a37acc", "#4cbf99", "#d1d1d1"]),
        TerminalColorTheme(name: "Catppuccin Frappe", background: "#303446", foreground: "#c6d0f5", cursor: "#f2d5cf", cursorText: "#303446", selectionBackground: "#626880", selectionForeground: "#c6d0f5",
                           palette: ["#51576d", "#e78284", "#a6d189", "#e5c890", "#8caaee", "#f4b8e4", "#81c8be", "#a5adce", "#626880", "#e67172", "#8ec772", "#d9ba73", "#7b9ef0", "#f2a4db", "#5abfb5", "#b5bfe2"]),
        TerminalColorTheme(name: "Catppuccin Latte", background: "#eff1f5", foreground: "#4c4f69", cursor: "#dc8a78", cursorText: "#eff1f5", selectionBackground: "#acb0be", selectionForeground: "#4c4f69",
                           palette: ["#5c5f77", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#acb0be", "#6c6f85", "#de293e", "#49af3d", "#eea02d", "#456eff", "#fe85d8", "#2d9fa8", "#bcc0cc"]),
        TerminalColorTheme(name: "Catppuccin Macchiato", background: "#24273a", foreground: "#cad3f5", cursor: "#f4dbd6", cursorText: "#24273a", selectionBackground: "#5b6078", selectionForeground: "#cad3f5",
                           palette: ["#494d64", "#ed8796", "#a6da95", "#eed49f", "#8aadf4", "#f5bde6", "#8bd5ca", "#a5adcb", "#5b6078", "#ec7486", "#8ccf7f", "#e1c682", "#78a1f6", "#f2a9dd", "#63cbc0", "#b8c0e0"]),
        TerminalColorTheme(name: "Catppuccin Mocha", background: "#1e1e2e", foreground: "#cdd6f4", cursor: "#f5e0dc", cursorText: "#1e1e2e", selectionBackground: "#585b70", selectionForeground: "#cdd6f4",
                           palette: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8", "#585b70", "#f37799", "#89d88b", "#ebd391", "#74a8fc", "#f2aede", "#6bd7ca", "#bac2de"]),
        TerminalColorTheme(name: "Dracula", background: "#282a36", foreground: "#f8f8f2", cursor: "#f8f8f2", cursorText: "#282a36", selectionBackground: "#44475a", selectionForeground: "#ffffff",
                           palette: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c", "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2", "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5", "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
        TerminalColorTheme(name: "Everforest Dark Hard", background: "#1e2326", foreground: "#d3c6aa", cursor: "#e69875", cursorText: "#4c3743", selectionBackground: "#4c3743", selectionForeground: "#d3c6aa",
                           palette: ["#7a8478", "#e67e80", "#a7c080", "#dbbc7f", "#7fbbb3", "#d699b6", "#83c092", "#f2efdf", "#a6b0a0", "#f85552", "#8da101", "#dfa000", "#3a94c5", "#df69ba", "#35a77c", "#fffbef"]),
        TerminalColorTheme(name: "Everforest Light Med", background: "#efebd4", foreground: "#5c6a72", cursor: "#f57d26", cursorText: "#eaedc8", selectionBackground: "#eaedc8", selectionForeground: "#5c6a72",
                           palette: ["#7a8478", "#e67e80", "#9ab373", "#c1a266", "#7fbbb3", "#d699b6", "#83c092", "#b2af9f", "#a6b0a0", "#f85552", "#8da101", "#dfa000", "#3a94c5", "#df69ba", "#35a77c", "#fffbef"]),
        TerminalColorTheme(name: "GitHub Dark", background: "#0d1117", foreground: "#e6edf3", cursor: "#2f81f7", cursorText: "#6fc1ff", selectionBackground: "#e6edf3", selectionForeground: "#0d1117",
                           palette: ["#484f58", "#ff7b72", "#3fb950", "#d29922", "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4", "#6e7681", "#ffa198", "#56d364", "#e3b341", "#79c0ff", "#d2a8ff", "#56d4dd", "#ffffff"]),
        TerminalColorTheme(name: "GitHub Light", background: "#ffffff", foreground: "#1f2328", cursor: "#0969da", cursorText: "#3c9cff", selectionBackground: "#1f2328", selectionForeground: "#ffffff",
                           palette: ["#24292f", "#cf222e", "#116329", "#4d2d00", "#0969da", "#8250df", "#1b7c83", "#6e7781", "#57606a", "#a40e26", "#1a7f37", "#633c01", "#218bff", "#a475f9", "#3192aa", "#8c959f"]),
        TerminalColorTheme(name: "Gruvbox Dark", background: "#282828", foreground: "#ebdbb2", cursor: "#ebdbb2", cursorText: "#282828", selectionBackground: "#665c54", selectionForeground: "#ebdbb2",
                           palette: ["#282828", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#a89984", "#928374", "#fb4934", "#b8bb26", "#fabd2f", "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        TerminalColorTheme(name: "Gruvbox Light", background: "#fbf1c7", foreground: "#3c3836", cursor: "#3c3836", cursorText: "#fbf1c7", selectionBackground: "#3c3836", selectionForeground: "#fbf1c7",
                           palette: ["#fbf1c7", "#cc241d", "#98971a", "#d79921", "#458588", "#b16286", "#689d6a", "#7c6f64", "#928374", "#9d0006", "#79740e", "#b57614", "#076678", "#8f3f71", "#427b58", "#3c3836"]),
        TerminalColorTheme(name: "Kanagawa Lotus", background: "#f2ecbc", foreground: "#545464", cursor: "#43436c", cursorText: "#f2ecbc", selectionBackground: "#545464", selectionForeground: "#f2ecbc",
                           palette: ["#1f1f28", "#c84053", "#6f894e", "#77713f", "#4d699b", "#b35b79", "#597b75", "#545464", "#8a8980", "#d7474b", "#6e915f", "#836f4a", "#6693bf", "#624c83", "#5e857a", "#43436c"]),
        TerminalColorTheme(name: "Kanagawa Wave", background: "#1f1f28", foreground: "#dcd7ba", cursor: "#dcd7ba", cursorText: "#1f1f28", selectionBackground: "#dcd7ba", selectionForeground: "#1f1f28",
                           palette: ["#090618", "#c34043", "#76946a", "#c0a36e", "#7e9cd8", "#957fb8", "#6a9589", "#c8c093", "#727169", "#e82424", "#98bb6c", "#e6c384", "#7fb4ca", "#938aa9", "#7aa89f", "#dcd7ba"]),
        TerminalColorTheme(name: "Monokai Pro", background: "#2d2a2e", foreground: "#fcfcfa", cursor: "#c1c0c0", cursorText: "#8e8d8d", selectionBackground: "#5b595c", selectionForeground: "#fcfcfa",
                           palette: ["#2d2a2e", "#ff6188", "#a9dc76", "#ffd866", "#fc9867", "#ab9df2", "#78dce8", "#fcfcfa", "#727072", "#ff6188", "#a9dc76", "#ffd866", "#fc9867", "#ab9df2", "#78dce8", "#fcfcfa"]),
        TerminalColorTheme(name: "Night Owl", background: "#011627", foreground: "#d6deeb", cursor: "#7e57c2", cursorText: "#ffffff", selectionBackground: "#5f7e97", selectionForeground: "#dfe5ee",
                           palette: ["#011627", "#ef5350", "#22da6e", "#addb67", "#82aaff", "#c792ea", "#21c7a8", "#ffffff", "#575656", "#ef5350", "#22da6e", "#ffeb95", "#82aaff", "#c792ea", "#7fdbca", "#ffffff"]),
        TerminalColorTheme(name: "Nord", background: "#2e3440", foreground: "#d8dee9", cursor: "#eceff4", cursorText: "#282828", selectionBackground: "#eceff4", selectionForeground: "#4c566a",
                           palette: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0", "#596377", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        TerminalColorTheme(name: "Nord Light", background: "#e5e9f0", foreground: "#414858", cursor: "#7bb3c3", cursorText: "#3b4252", selectionBackground: "#d8dee9", selectionForeground: "#4c556a",
                           palette: ["#3b4252", "#bf616a", "#96b17f", "#c5a565", "#81a1c1", "#b48ead", "#7bb3c3", "#a5abb6", "#4c566a", "#bf616a", "#96b17f", "#c5a565", "#81a1c1", "#b48ead", "#82afae", "#eceff4"]),
        TerminalColorTheme(name: "One Half Dark", background: "#282c34", foreground: "#dcdfe4", cursor: "#a3b3cc", cursorText: "#e9ecf1", selectionBackground: "#474e5d", selectionForeground: "#dcdfe4",
                           palette: ["#282c34", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4", "#5d677a", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#dcdfe4"]),
        TerminalColorTheme(name: "One Half Light", background: "#fafafa", foreground: "#383a42", cursor: "#a5b4e5", cursorText: "#383a42", selectionBackground: "#bfceff", selectionForeground: "#383a42",
                           palette: ["#383a42", "#e45649", "#50a14f", "#c18401", "#0184bc", "#a626a4", "#0997b3", "#bababa", "#4f525e", "#e06c75", "#98c379", "#d8b36e", "#61afef", "#c678dd", "#56b6c2", "#ffffff"]),
        TerminalColorTheme(name: "Rose Pine", background: "#191724", foreground: "#e0def4", cursor: "#e0def4", cursorText: "#191724", selectionBackground: "#403d52", selectionForeground: "#e0def4",
                           palette: ["#26233a", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4", "#6e6a86", "#eb6f92", "#31748f", "#f6c177", "#9ccfd8", "#c4a7e7", "#ebbcba", "#e0def4"]),
        TerminalColorTheme(name: "Rose Pine Dawn", background: "#faf4ed", foreground: "#575279", cursor: "#575279", cursorText: "#faf4ed", selectionBackground: "#dfdad9", selectionForeground: "#575279",
                           palette: ["#f2e9e1", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279", "#9893a5", "#b4637a", "#286983", "#ea9d34", "#56949f", "#907aa9", "#d7827e", "#575279"]),
        TerminalColorTheme(name: "Solarized Dark", background: "#002b36", foreground: "#839496", cursor: "#839496", cursorText: "#073642", selectionBackground: "#073642", selectionForeground: "#93a1a1",
                           palette: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5", "#335e69", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        TerminalColorTheme(name: "Solarized Light", background: "#fdf6e3", foreground: "#657b83", cursor: "#657b83", cursorText: "#eee8d5", selectionBackground: "#eee8d5", selectionForeground: "#586e75",
                           palette: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#bbb5a2", "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        TerminalColorTheme(name: "Tokyo Night", background: "#1a1b26", foreground: "#c0caf5", cursor: "#c0caf5", cursorText: "#15161e", selectionBackground: "#33467c", selectionForeground: "#c0caf5",
                           palette: ["#15161e", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6", "#414868", "#f7768e", "#9ece6a", "#e0af68", "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5"]),
        TerminalColorTheme(name: "Tokyo Night Day", background: "#e1e2e7", foreground: "#3760bf", cursor: "#3760bf", cursorText: "#e1e2e7", selectionBackground: "#99a7df", selectionForeground: "#3760bf",
                           palette: ["#e9e9ed", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#6172b0", "#a1a6c5", "#f52a65", "#587539", "#8c6c3e", "#2e7de9", "#9854f1", "#007197", "#3760bf"]),
        TerminalColorTheme(name: "Tomorrow", background: "#ffffff", foreground: "#4d4d4c", cursor: "#4d4d4c", cursorText: "#ffffff", selectionBackground: "#d6d6d6", selectionForeground: "#4d4d4c",
                           palette: ["#000000", "#c82829", "#718c00", "#eab700", "#4271ae", "#8959a8", "#3e999f", "#bfbfbf", "#000000", "#c82829", "#718c00", "#eab700", "#4271ae", "#8959a8", "#3e999f", "#ffffff"]),
        TerminalColorTheme(name: "Tomorrow Night", background: "#1d1f21", foreground: "#c5c8c6", cursor: "#c5c8c6", cursorText: "#1d1f21", selectionBackground: "#373b41", selectionForeground: "#c5c8c6",
                           palette: ["#000000", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#ffffff", "#4c4c4c", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#ffffff"]),
        TerminalColorTheme(name: "Xcode Dark", background: "#292a30", foreground: "#dfdfe0", cursor: "#dfdfe0", cursorText: "#292a30", selectionBackground: "#414453", selectionForeground: "#dfdfe0",
                           palette: ["#414453", "#ff8170", "#78c2b3", "#d9c97c", "#4eb0cc", "#ff7ab2", "#b281eb", "#dfdfe0", "#7f8c98", "#ff8170", "#acf2e4", "#ffa14f", "#6bdfff", "#ff7ab2", "#dabaff", "#dfdfe0"]),
        TerminalColorTheme(name: "Xcode Light", background: "#ffffff", foreground: "#262626", cursor: "#262626", cursorText: "#ffffff", selectionBackground: "#b4d8fd", selectionForeground: "#262626",
                           palette: ["#b4d8fd", "#d12f1b", "#3e8087", "#78492a", "#0f68a0", "#ad3da4", "#804fb8", "#262626", "#8a99a6", "#d12f1b", "#23575c", "#78492a", "#0b4f79", "#ad3da4", "#4b21b0", "#262626"]),
    ]
}

public extension TerminalThemeCatalog {
    /// Terminal.app's "Basic" ANSI colors, which read on both light and dark backgrounds.
    static let basicANSI = [
        "#000000", "#990000", "#00a600", "#999900", "#0000b2", "#b200b2", "#00a6b2", "#bfbfbf",
        "#666666", "#e50000", "#00d900", "#e5e500", "#0000ff", "#e500e5", "#00e5e5", "#e5e5e5",
    ]
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

public extension TerminalColorTheme {
    /// The system text colors for light or dark mode with the basic ANSI colors: what a
    /// terminal shows when no theme is chosen.
    @MainActor
    static func system(dark: Bool) -> TerminalColorTheme {
        var theme = TerminalColorTheme(name: "System", background: "#ffffff", foreground: "#000000", palette: TerminalThemeCatalog.basicANSI)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            theme.background = NSColor.textBackgroundColor.terminalHex
            theme.foreground = NSColor.textColor.terminalHex
            theme.cursor = theme.foreground
            theme.cursorText = theme.background
            theme.selectionBackground = NSColor.selectedTextBackgroundColor.terminalHex
            theme.selectionForeground = theme.foreground
        }
        return theme
    }
}

public extension NSColor {
    /// `#rrggbb` in sRGB.
    var terminalHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }
}
#endif
