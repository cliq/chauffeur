import Foundation

/// An issue-tracker ticket recognised in pasted text, without contacting the tracker.
public struct TicketReference: Equatable, Sendable {
    /// The tracker key as written, uppercased (`MBL-8593`); nil for trackers that only number issues.
    public var key: String?
    /// The numeric part (`8593`).
    public var number: String
    /// The pasted link; nil when the text was a bare key.
    public var url: String?

    public init(key: String?, number: String, url: String? = nil) {
        self.key = key; self.number = number; self.url = url
    }

    /// Recognises a ticket URL (Jira, Linear, GitHub, GitLab, or any URL with a `KEY-123` path segment)
    /// or a bare key such as `MBL-8593`. Other text, including titles that merely mention a key, returns nil.
    public static func parse(_ text: String) -> TicketReference? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if let key = key(trimmed, uppercaseOnly: false) { return TicketReference(key: key.key, number: key.number) }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme), components.host?.isEmpty == false else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        // Numbered trackers first: a repository named like a key (`acme/app-2`) must not win over its issue number.
        for (index, segment) in path.enumerated() where ["issues", "pull", "merge_requests"].contains(segment) {
            if index + 1 < path.count, isNumber(path[index + 1]) { return TicketReference(key: nil, number: path[index + 1], url: trimmed) }
        }
        let candidates = (components.queryItems ?? []).filter { $0.name == "selectedIssue" }.compactMap(\.value) + path
        for candidate in candidates {
            // URL slugs are lowercase, so only uppercase segments count as keys there.
            if let key = key(candidate, uppercaseOnly: true) { return TicketReference(key: key.key, number: key.number, url: trimmed) }
        }
        return nil
    }

    private static func key(_ text: String, uppercaseOnly: Bool) -> (key: String, number: String)? {
        guard let hyphen = text.lastIndex(of: "-") else { return nil }
        let project = text[..<hyphen], number = String(text[text.index(after: hyphen)...])
        guard project.count >= 2, let first = project.unicodeScalars.first, isNumber(number),
              CharacterSet.letters.contains(first), first.isASCII,
              project.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }) else { return nil }
        if uppercaseOnly, project != project.uppercased() { return nil }
        return (project.uppercased() + "-" + number, number)
    }

    private static func isNumber(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.decimalDigits.contains($0) }
    }
}

/// Turns a ticket into a branch name with a repository's template.
public enum TicketBranchTemplate {
    public static let defaultTemplate = "{key}"
    public static let tokens = ["{key}", "{KEY}", "{number}"]

    /// `{key}` is the lowercased key, `{KEY}` the key as written, and `{number}` its number.
    /// Trackers without keys substitute the number for both key tokens. Unknown tokens stay as typed.
    public static func render(_ template: String?, ticket: TicketReference) -> String {
        let trimmed = template?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = ticket.key ?? ticket.number
        return (trimmed.isEmpty ? defaultTemplate : trimmed)
            .replacingOccurrences(of: "{KEY}", with: key)
            .replacingOccurrences(of: "{key}", with: key.lowercased())
            .replacingOccurrences(of: "{number}", with: ticket.number)
    }
}

/// What the launch forms apply when their title or branch field holds a ticket.
public struct TicketResolution: Codable, Equatable, Sendable {
    public var key: String?
    public var number: String
    /// Set when the text was a link; forms only rewrite their fields for links.
    public var url: String?
    public var branch: String
    /// The session title that replaces a pasted link: the key, or `#123` for numbered trackers.
    public var title: String
    /// The initial task to use when the form has none; nil unless the folder puts links in tasks.
    public var task: String?

    public init(key: String?, number: String, url: String?, branch: String, title: String, task: String?) {
        self.key = key; self.number = number; self.url = url; self.branch = branch; self.title = title; self.task = task
    }

    public static func resolve(_ text: String, folder: ProjectFolder) -> TicketResolution? {
        guard let ticket = TicketReference.parse(text) else { return nil }
        let task = folder.putsTicketLinkInTask ? ticket.url : nil
        return TicketResolution(key: ticket.key, number: ticket.number, url: ticket.url,
                                branch: TicketBranchTemplate.render(folder.branchTemplate, ticket: ticket),
                                title: ticket.key ?? "#" + ticket.number, task: task)
    }
}
