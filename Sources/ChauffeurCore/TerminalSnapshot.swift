import Foundation

/// A bounded, read-only rendering of a terminal, separate from native conversations.
/// Live reattachment always uses tmux's current redraw and process identity.
public struct TerminalSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumFileBytes = 4 * 1024 * 1024
    public var version = currentVersion
    public var sessionID: UUID
    public var processID: Int32
    public var terminalIdentity: String
    public var capturedAt: Date
    public var columns: Int
    public var rows: Int
    public var lineLimit: Int
    public var history: String
    public var screen: String
    public var truncated: Bool

    public init(sessionID: UUID, processID: Int32, terminalIdentity: String, columns: Int, rows: Int, lineLimit: Int, history: String, screen: String, truncated: Bool = false, capturedAt: Date = Date()) {
        self.sessionID = sessionID; self.processID = processID; self.terminalIdentity = terminalIdentity
        self.columns = columns; self.rows = rows; self.lineLimit = lineLimit; self.capturedAt = capturedAt
        self.history = history; self.screen = screen; self.truncated = truncated
    }
    public func validate() throws {
        guard version == Self.currentVersion else { throw ChauffeurError("snapshot_version", "Saved terminal history uses an unsupported format") }
        try Validation.require((2...500).contains(columns) && (2...300).contains(rows), "Invalid saved terminal dimensions")
        try Validation.require((100...100_000).contains(lineLimit), "Invalid saved terminal history limit")
        try Validation.require(processID > 0 && terminalIdentity.hasPrefix("%") && Int(terminalIdentity.dropFirst()) != nil, "Invalid saved terminal ownership")
    }
    /// Keep complete recent lines. Only SGR colour/style escapes may be replayed;
    /// clipboard, cursor, query and other terminal controls never enter an archive.
    public mutating func bound(lines: Int, maximumBytes: Int) throws {
        lineLimit = lines
        try validate()
        history = Self.safeANSI(history); screen = Self.safeANSI(screen)
        let historyLines = history.split(separator: "\n", omittingEmptySubsequences: false)
        let components = lines + (history.hasSuffix("\n") ? 1 : 0)
        if historyLines.count > components { history = historyLines.suffix(components).joined(separator: "\n"); truncated = true }
        let budget = max(4096, min(maximumBytes, Self.maximumFileBytes))
        // Encoding can expand control characters. Check actual persisted bytes.
        while try JSONCoding.encode(self).count > budget {
            truncated = true
            if !history.isEmpty { history = Self.recentHalf(history) }
            else if !screen.isEmpty { screen = Self.recentHalf(screen) }
            else { throw ChauffeurError("snapshot_budget", "Snapshot metadata exceeds its byte limit") }
        }
        try validate()
    }
    private static func recentHalf(_ value: String) -> String {
        let tail = value.suffix(max(0, value.count / 2))
        if let newline = tail.firstIndex(of: "\n") { return String(tail[tail.index(after: newline)...]) }
        return "" // An oversized single line cannot be kept as a complete line.
    }
    public static func safeANSI(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView(), index = 0
        while index < scalars.count {
            let value = scalars[index].value
            // Eight-bit string controls must discard their payload as well.
            if [0x90, 0x98, 0x9d, 0x9e, 0x9f].contains(value) {
                index += 1
                while index < scalars.count {
                    if scalars[index].value == 7 || scalars[index].value == 0x9c { index += 1; break }
                    if scalars[index].value == 27 && index + 1 < scalars.count && scalars[index + 1] == "\\" { index += 2; break }
                    index += 1
                }
                continue
            }
            if value == 27 {
                index += 1
                guard index < scalars.count else { break }
                if scalars[index] == "[" {
                    let start = index; index += 1
                    while index < scalars.count && !(0x40...0x7e).contains(scalars[index].value) { index += 1 }
                    if index < scalars.count, scalars[index] == "m", index - start <= 128,
                       scalars[(start + 1)..<index].allSatisfy({ (48...57).contains($0.value) || $0 == ";" || $0 == ":" }) {
                        result.append("\u{1b}"); result.append(contentsOf: scalars[start...index])
                    }
                    if index < scalars.count { index += 1 }
                } else if ["]", "P", "_", "^", "X"].contains(String(scalars[index])) {
                    index += 1
                    while index < scalars.count {
                        if scalars[index].value == 7 || scalars[index].value == 0x9c { index += 1; break }
                        if scalars[index].value == 27 && index + 1 < scalars.count && scalars[index + 1] == "\\" { index += 2; break }
                        index += 1
                    }
                } else { index += 1 }
            } else {
                if value == 10 || value == 9 || value >= 32 && !(0x7f...0x9f).contains(value) { result.append(scalars[index]) }
                index += 1
            }
        }
        return String(result)
    }
    public var rendering: String { (Self.safeANSI(history) + "\u{1b}[0m" + Self.safeANSI(screen) + "\u{1b}[0m").replacingOccurrences(of: "\n", with: "\r\n") }
}

public struct SnapshotStorageStatus: Codable, Sendable {
    public var files: Int
    public var bytes: Int
    public var budgetBytes: Int
    public var evictedFiles: Int
    public init(files: Int = 0, bytes: Int = 0, budgetBytes: Int, evictedFiles: Int = 0) {
        self.files = files; self.bytes = bytes; self.budgetBytes = budgetBytes; self.evictedFiles = evictedFiles
    }
}
