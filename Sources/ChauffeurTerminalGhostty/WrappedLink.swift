import Foundation

/// Rebuilds a URL that a program wrapped across rows itself.
///
/// Ghostty only joins rows the terminal soft-wrapped. Behind tmux, and in agents that break long
/// words onto an indented next row, a URL arrives as separate rows and Ghostty's link stops at the
/// row's edge. A row that is full to the edge and ends in URL characters continues on the next
/// row's first word, which may be indented.
enum WrappedLink {
    /// Rows to look at on each side of the clicked one.
    static let maximumRows = 20

    /// The URL under `column` of `rows[row]` when it spans more than one row, else nil.
    ///
    /// Columns are taken as character offsets, so a row with wide characters before the URL
    /// may miss it; the caller then keeps Ghostty's own link.
    static func url(rows: [String], row: Int, column: Int, columns: Int) -> String? {
        let lines = rows.map { Array($0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)) }
        guard lines.indices.contains(row), columns > 1, let clicked = run(in: lines[row], at: column) else { return nil }
        func isFull(_ index: Int) -> Bool { lines[index].count >= columns - 1 }
        func firstWord(_ index: Int) -> Range<Int>? {
            guard let start = lines[index].firstIndex(where: { !$0.isWhitespace }), let word = run(in: lines[index], at: start),
                  word.lowerBound == start else { return nil }
            return word
        }

        var segments = [(row: row, range: clicked)]
        while segments.count < maximumRows, let first = segments.first, first.row > 0, first.range == firstWord(first.row),
              continues(lines[first.row], first.range, full: isFull(first.row)),
              isFull(first.row - 1), let previous = run(in: lines[first.row - 1], at: lines[first.row - 1].count - 1),
              previous.upperBound == lines[first.row - 1].count {
            segments.insert((first.row - 1, previous), at: 0)
        }
        let clickedIndex = segments.count - 1
        while segments.count < 2 * maximumRows, let last = segments.last, last.row + 1 < lines.count,
              last.range.upperBound == lines[last.row].count, isFull(last.row), let next = firstWord(last.row + 1),
              continues(lines[last.row + 1], next, full: isFull(last.row + 1)) {
            segments.append((last.row + 1, next))
        }
        guard segments.count > 1 else { return nil }

        let parts = segments.map { String(lines[$0.row][$0.range]) }
        let joined = parts.joined()
        let clickedEnd = parts[...clickedIndex].reduce(0) { $0 + $1.utf16.count }
        // The URL starts at the first scheme before the end of the clicked row, so a full row of
        // prose above a URL doesn't become part of it. A scheme starts a word or a row.
        var boundaries = Set<Int>(), offsetSoFar = 0
        for part in parts { boundaries.insert(offsetSoFar); offsetSoFar += part.utf16.count }
        let text = joined as NSString
        guard let match = scheme.matches(in: joined, range: NSRange(location: 0, length: text.length)).first(where: { match in
                  let location = match.range.location
                  guard location < clickedEnd else { return false }
                  guard location > 0, !boundaries.contains(location) else { return true }
                  let previous = Character(text.substring(with: NSRange(location: location - 1, length: 1)))
                  return !(previous.isLetter || previous.isNumber)
              }),
              let start = Range(match.range, in: joined)?.lowerBound else { return nil }
        let url = trimmed(String(joined[start...]))
        // A URL that fits on one row is Ghostty's to find.
        let startOffset = match.range.location
        var offset = 0
        let spanned = parts.filter { part in
            defer { offset += part.utf16.count }
            return offset + part.utf16.count > startOffset && offset < startOffset + url.utf16.count
        }
        guard spanned.count > 1 else { return nil }
        return url
    }

    private static let scheme = try! NSRegularExpression(
        pattern: "(?:https?|ftp|sftp|ssh|git|file|gemini|gopher|ipfs|ipns)://|mailto:|magnet:\\?", options: [.caseInsensitive]
    )

    /// Whether the first word of a row carries on a URL that filled the row above. A plain word
    /// followed by more text is prose after a URL that happened to end at the edge.
    private static func continues(_ line: [Character], _ word: Range<Int>, full: Bool) -> Bool {
        full || word.upperBound == line.count || line[word].contains { !($0.isLetter || $0.isNumber) }
    }

    /// The run of URL characters in `line` that contains `index`.
    private static func run(in line: [Character], at index: Int) -> Range<Int>? {
        guard line.indices.contains(index), isURLCharacter(line[index]) else { return nil }
        var lower = index, upper = index + 1
        while lower > 0, isURLCharacter(line[lower - 1]) { lower -= 1 }
        while upper < line.count, isURLCharacter(line[upper]) { upper += 1 }
        return lower..<upper
    }

    private static func isURLCharacter(_ character: Character) -> Bool {
        guard character.isASCII, let scalar = character.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || "-._~:/?#[]@!$&'()*+,;=%".contains(character)
    }

    /// Drops sentence punctuation after the URL and closing brackets it never opened.
    private static func trimmed(_ url: String) -> String {
        var url = url
        while let last = url.last {
            if ".,;:!?'".contains(last) {
                url.removeLast()
            } else if let opening = [")": "(", "]": "["][String(last)],
                      url.filter({ String($0) == opening }).count < url.filter({ $0 == last }).count {
                url.removeLast()
            } else {
                break
            }
        }
        return url
    }
}
