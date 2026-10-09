import Foundation

/// Decides what a link tapped inside a rendered document opens.
enum DocumentLinkResolver {
    enum Target: Equatable {
        case web(URL)
        case document(String)
    }

    /// Returns nil for links that should do nothing (empty or fragment-only).
    static func resolve(_ href: String, relativeTo documentPath: String) -> Target? {
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !href.isEmpty, !href.hasPrefix("#") else { return nil }
        let lower = href.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            return URL(string: href).map(Target.web)
        }
        var pathPart = href
        if lower.hasPrefix("file://") { pathPart = String(href.dropFirst("file://".count)) }
        if let index = pathPart.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            pathPart = String(pathPart[..<index])
        }
        pathPart = pathPart.removingPercentEncoding ?? pathPart
        guard !pathPart.isEmpty else { return nil }
        let resolved: URL
        if pathPart.hasPrefix("/") {
            resolved = URL(fileURLWithPath: pathPart)
        } else {
            let directory = URL(fileURLWithPath: documentPath).deletingLastPathComponent()
            resolved = URL(fileURLWithPath: pathPart, relativeTo: directory)
        }
        return .document(resolved.standardizedFileURL.path)
    }
}
