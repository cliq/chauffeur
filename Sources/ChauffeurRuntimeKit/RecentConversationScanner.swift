import Foundation
import CSQLite
import ChauffeurCore

/// Reads the conversations Claude Code, Codex and OpenCode recorded for one
/// checkout. Reading is best-effort: an unreadable or unfamiliar transcript is
/// skipped, never reported, because the provider owns these formats.
public enum RecentConversationScanner {
    public struct Sources: Equatable, Sendable {
        public var claude: [String] = []
        public var codex: [String] = []
        public var openCodeDatabases: [String] = []
        public init(claude: [String] = [], codex: [String] = [], openCodeDatabases: [String] = []) {
            self.claude = claude; self.codex = codex; self.openCodeDatabases = openCodeDatabases
        }
    }

    public static func scan(path: String, sources: Sources, limit: Int = 25) -> [RecentConversation] {
        let checkout = Paths.canonical(path)
        var found = claude(checkout: checkout, configurations: sources.claude, limit: limit)
        found += sources.codex.flatMap { codex(checkout: checkout, configuration: $0, limit: limit) }
        found += sources.openCodeDatabases.flatMap { openCode(checkout: checkout, database: $0, limit: limit) }
        var seen = Set<String>()
        return found.sorted { $0.updatedAt > $1.updatedAt }.filter { seen.insert("\($0.kind.rawValue):\($0.id)").inserted }.prefix(limit).map { $0 }
    }

    /// Claude Code names a project folder after the working directory with
    /// every character outside `[A-Za-z0-9]` replaced by a dash.
    public static func claudeProjectFolder(_ path: String) -> String {
        String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    // MARK: Claude Code

    /// Transcripts across every profile are read newest first, and reading
    /// stops once `limit` of them belong to the checkout.
    static func claude(checkout: String, configurations: [String], limit: Int) -> [RecentConversation] {
        let folder = claudeProjectFolder(checkout)
        let files = configurations.flatMap { configuration in
            transcripts(in: URL(fileURLWithPath: configuration).appendingPathComponent("projects").appendingPathComponent(folder)).map { (url: $0.url, modified: $0.modified, configuration: configuration) }
        }.sorted { $0.modified > $1.modified }
        var found: [RecentConversation] = []
        for file in files where found.count < limit {
            if let conversation = claudeConversation(file.url, checkout: checkout, modified: file.modified, configuration: file.configuration) { found.append(conversation) }
        }
        return found
    }

    private static let claudeTitleMarkers = [Data(#""type":"ai-title""#.utf8), Data(#""type":"custom-title""#.utf8)]
    private static let claudeUserMarker = Data(#""type":"user""#.utf8)
    private static let cwdMarker = Data(#""cwd":"#.utf8)

    private static func claudeConversation(_ url: URL, checkout: String, modified: Date, configuration: String) -> RecentConversation? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var cwd: String?, started: Date?, prompt: String?, aiTitle: String?, customTitle: String?
        for line in lines(data) {
            // Most lines are tool traffic; decode only the lines still needed.
            let title = claudeTitleMarkers.contains { contains(line, $0) }
            let needed = title || (cwd == nil && contains(line, cwdMarker)) || (prompt == nil && contains(line, claudeUserMarker))
            guard needed, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if cwd == nil, let value = object["cwd"] as? String {
                cwd = value
                // Distinct paths can share a folder name; the recorded directory decides.
                guard Paths.canonical(value) == checkout else { return nil }
            }
            if started == nil, let value = object["timestamp"] as? String { started = timestamp(value) }
            switch object["type"] as? String {
            case "custom-title": customTitle = (object["customTitle"] as? String) ?? customTitle
            case "ai-title": aiTitle = (object["aiTitle"] as? String) ?? aiTitle
            case "user" where prompt == nil && object["isMeta"] as? Bool != true && object["isSidechain"] as? Bool != true:
                prompt = typedPrompt((object["message"] as? [String: Any])?["content"])
            default: break
            }
        }
        guard cwd != nil, let prompt else { return nil }
        return RecentConversation(id: url.deletingPathExtension().lastPathComponent, kind: .claude, title: customTitle ?? aiTitle ?? summary(prompt), prompt: prompt,
                                  startedAt: started, updatedAt: modified, configurationDirectory: configuration, transcriptPath: url.path)
    }

    // MARK: Codex

    static func codex(checkout: String, configuration: String, limit: Int) -> [RecentConversation] {
        let root = URL(fileURLWithPath: configuration)
        guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent("sessions"), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var matches: [(url: URL, id: String, started: Date?, modified: Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            // The first line is the session's metadata, including where it ran.
            guard let first = firstLine(url), let object = (try? JSONSerialization.jsonObject(with: first)) as? [String: Any],
                  object["type"] as? String == "session_meta", let meta = object["payload"] as? [String: Any],
                  let id = meta["id"] as? String, let cwd = meta["cwd"] as? String, Paths.canonical(cwd) == checkout,
                  // Spawned sub-agents record an object source; they belong to their parent.
                  meta["source"] is String || meta["source"] == nil else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            matches.append((url, id, (meta["timestamp"] as? String).flatMap(timestamp), modified))
        }
        guard !matches.isEmpty else { return [] }
        let names = codexThreadNames(root.appendingPathComponent("session_index.jsonl"))
        // Only the newest can be listed, so only they pay for a full read.
        return matches.sorted { $0.modified > $1.modified }.prefix(limit).compactMap { match in
            let prompt = codexPrompt(match.url)
            guard let title = names[match.id] ?? prompt.map(summary) else { return nil }
            return RecentConversation(id: match.id, kind: .codex, title: title, prompt: prompt, startedAt: match.started, updatedAt: match.modified,
                                      configurationDirectory: configuration, transcriptPath: match.url.path)
        }
    }

    private static func codexThreadNames(_ index: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: index) else { return [:] }
        var names: [String: String] = [:]
        for line in lines(data) {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = object["id"] as? String, let name = object["thread_name"] as? String, !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }

    private static let codexUserMarker = Data(#""role":"user""#.utf8)

    private static func codexPrompt(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var prompt: String?
        eachLine(data) { line in
            guard contains(line, codexUserMarker), let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any], payload["type"] as? String == "message", payload["role"] as? String == "user" else { return true }
            prompt = typedPrompt(payload["content"])
            return prompt == nil
        }
        return prompt
    }

    // MARK: OpenCode

    public static func openCodeDatabase(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String {
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? URL(fileURLWithPath: home).appendingPathComponent(".local/share").path
        return URL(fileURLWithPath: data).appendingPathComponent("opencode/opencode.db").path
    }

    static func openCode(checkout: String, database path: String, limit: Int) -> [RecentConversation] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        let query = "SELECT id, title, time_created, time_updated FROM session WHERE directory = ?1 AND parent_id IS NULL AND time_archived IS NULL ORDER BY time_updated DESC LIMIT ?2"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, checkout, -1, transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var found: [RecentConversation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            let stored = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            // OpenCode names a conversation "New session - <date>" until it titles it.
            let title = stored.isEmpty || stored.hasPrefix("New session - ") ? "Untitled conversation" : stored
            found.append(RecentConversation(id: id, kind: .opencode, title: title,
                                            startedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1000),
                                            updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)))
        }
        return found
    }

    // MARK: Helpers

    private static func transcripts(in folder: URL) -> [(url: URL, modified: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
    }

    /// The text a person typed. Harness wrappers such as command echoes,
    /// caveats and injected project instructions arrive as user messages too.
    static func typedPrompt(_ content: Any?) -> String? {
        let texts: [String]
        if let text = content as? String { texts = [text] }
        else if let parts = content as? [[String: Any]] { texts = parts.compactMap { $0["text"] as? String } }
        else { return nil }
        let typed = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("# AGENTS.md instructions") }
        return typed.isEmpty ? nil : typed.joined(separator: "\n")
    }

    private static func summary(_ prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    /// `Data.range(of:)` is too slow for multi-megabyte transcripts.
    private static func contains(_ haystack: Data, _ needle: Data) -> Bool {
        haystack.withUnsafeBytes { hay in needle.withUnsafeBytes { pin in
            guard let base = hay.baseAddress, let pattern = pin.baseAddress else { return false }
            return memmem(base, hay.count, pattern, pin.count) != nil
        } }
    }

    private static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    }

    /// Visits lines in order until `body` returns false.
    private static func eachLine(_ data: Data, _ body: (Data) -> Bool) {
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            if end > start, !body(data[start..<end]) { return }
            start = data.index(after: end)
        }
    }

    private static func firstLine(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        // Session metadata carries the base instructions, so it can be long.
        while buffer.count < 4 * 1024 * 1024, let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let end = chunk.firstIndex(of: UInt8(ascii: "\n")) { return buffer + chunk[chunk.startIndex..<end] }
            buffer.append(chunk)
        }
        return buffer.isEmpty ? nil : buffer
    }
}
