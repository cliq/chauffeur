import Foundation

/// Extracts candidate markdown document paths from joined, escape-free terminal text.
/// Limitation: paths containing spaces are not matched.
enum DocumentPathHarvester {
    private static let pattern = try! NSRegularExpression(
        pattern: #"[^\s"'`()\[\]<>{}|]+?\.(?:md|markdown|mdx)(?::\d+){0,2}(?![\w/-])"#,
        options: [.caseInsensitive])
    private static let lineSuffix = try! NSRegularExpression(pattern: #"(?::\d+){1,2}$"#)
    private static let relative = try! NSRegularExpression(pattern: #"^[\w.@+-]+(/[\w.@+-]+)*$"#)
    private static let scheme = try! NSRegularExpression(pattern: #"^[A-Za-z][A-Za-z0-9+.-]*:"#)

    /// Most recent mention first, de-duplicated.
    static func paths(in text: String) -> [String] {
        let whole = NSRange(text.startIndex..., in: text)
        var seen = Set<String>(), result = [String]()
        for match in pattern.matches(in: text, range: whole).reversed() {
            guard let range = Range(match.range, in: text), let path = normalize(String(text[range])), seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    private static func normalize(_ raw: String) -> String? {
        var token = raw
        let trim = CharacterSet(charactersIn: "`'\"()[]<>.,;:")
        // Strip leading wrappers and trailing punctuation, but keep the `./` and `../` prefixes intact.
        while let first = token.unicodeScalars.first, "`'\"([<".unicodeScalars.contains(first) { token.removeFirst() }
        while let last = token.unicodeScalars.last, trim.contains(last), !isMarkdownExtensionEnd(token) { token.removeLast() }
        token = lineSuffix.stringByReplacingMatches(in: token, range: NSRange(token.startIndex..., in: token), withTemplate: "")
        guard !token.isEmpty else { return nil }
        if token.lowercased().hasPrefix("file://") {
            guard let url = URL(string: token), url.isFileURL, !url.path.isEmpty else { return nil }
            return url.path
        }
        if scheme.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil { return nil }
        if token.hasPrefix("/") || token.hasPrefix("~/") || token.hasPrefix("./") || token.hasPrefix("../") { return token }
        return relative.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil ? token : nil
    }

    private static func isMarkdownExtensionEnd(_ token: String) -> Bool {
        let lower = token.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".mdx")
    }
}
