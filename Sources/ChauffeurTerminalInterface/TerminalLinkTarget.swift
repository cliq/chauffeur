import Foundation

/// What a link the user tapped in the terminal points at. Pure and portable so every engine and
/// the link menu route links the same way.
public enum TerminalLinkTarget: Equatable, Sendable {
    /// An http, https or mailto URL, opened outside the app.
    case web(URL)
    /// A file path, with any `file://` percent-encoding and trailing `:line[:col]` removed.
    case file(path: String)
    /// Any other scheme or text that does not look like a path. Never opened.
    case other

    /// Extensions that make a bare token such as `README.md` a file rather than a host name.
    private static let fileExtensions: Set<String> = [
        "md", "markdown", "mdx", "txt", "swift", "json", "yml", "yaml", "toml", "js", "ts", "py", "rb", "go",
        "rs", "sh", "html", "css", "log", "plist", "xml", "c", "h", "m", "cpp", "kt", "java",
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg",
    ]

    public static func classify(_ link: String) -> TerminalLinkTarget {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .other }

        if let scheme = scheme(of: text) {
            switch scheme {
            case "http", "https", "mailto":
                guard let url = URL(string: text) else { return .other }
                return .web(url)
            case "file":
                guard let path = URL(string: text)?.path, !path.isEmpty else { return .other }
                return .file(path: path)
            default:
                return .other
            }
        }

        let path = strippingLineSuffix(text)
        guard !path.isEmpty else { return .other }
        if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../") || path.contains("/") {
            return .file(path: path)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        return fileExtensions.contains(ext) ? .file(path: path) : .other
    }

    /// The lowercased URL scheme, or nil when the text is a path. A trailing `:12` or `:12:3` after a
    /// file name (`x.md:12`) is a line suffix, not a scheme separator.
    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[..<colon]
        guard let first = head.first, first.isASCII, first.isLetter,
              head.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }) else { return nil }
        let rest = text[text.index(after: colon)...]
        if !rest.isEmpty, rest.split(separator: ":", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return nil
        }
        return head.lowercased()
    }

    private static func strippingLineSuffix(_ text: String) -> String {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false)
        var removed = 0
        while parts.count > 1, removed < 2, let last = parts.last, !last.isEmpty, last.allSatisfy(\.isNumber) {
            parts.removeLast()
            removed += 1
        }
        return parts.joined(separator: ":")
    }
}
