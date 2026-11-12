import Foundation

/// Text matching for the sidebar's filter fields: every word of the query must
/// appear in one of the fields, ignoring case and diacritics.
public enum SidebarFilter {
    /// The query's words, or `nil` when the field filters nothing.
    public static func query(_ text: String) -> [String]? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return words.isEmpty ? nil : words
    }
    public static func matches(_ query: [String], _ fields: String...) -> Bool {
        query.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
