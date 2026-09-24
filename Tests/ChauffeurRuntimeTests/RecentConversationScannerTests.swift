import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct RecentConversationScannerTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-recent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return URL(fileURLWithPath: Paths.canonical(root.path))
    }
    private func write(_ lines: [[String: Any]], to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    @Test func claudeTranscriptsUseTheirLatestTitleAndTypedPrompt() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("repo.worktree").path
        try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        let configuration = root.appendingPathComponent("claude")
        let folder = configuration.appendingPathComponent("projects").appendingPathComponent(RecentConversationScanner.claudeProjectFolder(checkout))
        #expect(!RecentConversationScanner.claudeProjectFolder(checkout).contains("."))
        try write([
            ["type": "system", "cwd": checkout, "timestamp": "2026-09-24T14:00:00.000Z"],
            ["type": "user", "isMeta": false, "cwd": checkout, "message": ["role": "user", "content": [["type": "text", "text": "<command-name>/model</command-name>"]]]],
            ["type": "user", "isMeta": false, "cwd": checkout, "message": ["role": "user", "content": [["type": "text", "text": "Fix the sidebar"], ["type": "image"]]]],
            ["type": "ai-title", "aiTitle": "First title"],
            ["type": "ai-title", "aiTitle": "Sidebar fix"],
        ], to: folder.appendingPathComponent("11111111-1111-1111-1111-111111111111.jsonl"), modified: Date(timeIntervalSince1970: 2_000))
        // Another directory can map to the same folder name; its cwd excludes it.
        try write([["type": "user", "cwd": root.appendingPathComponent("repo-worktree").path, "message": ["content": "Elsewhere"]]],
                  to: folder.appendingPathComponent("22222222-2222-2222-2222-222222222222.jsonl"))
        // A transcript without a typed prompt is an empty launch.
        try write([["type": "system", "cwd": checkout]], to: folder.appendingPathComponent("33333333-3333-3333-3333-333333333333.jsonl"))

        let found = RecentConversationScanner.scan(path: checkout, sources: .init(claude: [configuration.path]))
        #expect(found.count == 1)
        #expect(found.first?.id == "11111111-1111-1111-1111-111111111111")
        #expect(found.first?.kind == .claude)
        #expect(found.first?.title == "Sidebar fix")
        #expect(found.first?.prompt == "Fix the sidebar")
        #expect(found.first?.configurationDirectory == configuration.path)
    }

    @Test func codexRolloutsMatchTheirRecordedDirectoryAndSkipSubagents() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("repo").path
        let configuration = root.appendingPathComponent("codex")
        let day = configuration.appendingPathComponent("sessions/2026/09/24")
        func meta(_ id: String, cwd: String, source: Any = "cli") -> [String: Any] {
            ["type": "session_meta", "payload": ["id": id, "cwd": cwd, "source": source, "timestamp": "2026-09-24T14:10:04.648Z"]]
        }
        let prompt: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "What does MWAPPS-562 need?"]]]]
        let instructions: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>…</environment_context>"]]]]
        try write([meta("named", cwd: checkout), instructions, prompt], to: day.appendingPathComponent("rollout-a-named.jsonl"), modified: Date(timeIntervalSince1970: 3_000))
        try write([meta("unnamed", cwd: checkout), prompt], to: day.appendingPathComponent("rollout-b-unnamed.jsonl"), modified: Date(timeIntervalSince1970: 1_000))
        try write([meta("child", cwd: checkout, source: ["subagent": ["thread_spawn": [:]]]), prompt], to: day.appendingPathComponent("rollout-c-child.jsonl"))
        try write([meta("other", cwd: root.path), prompt], to: day.appendingPathComponent("rollout-d-other.jsonl"))
        try write([["id": "named", "thread_name": "Old name"], ["id": "named", "thread_name": "Review MWAPPS-562"]], to: configuration.appendingPathComponent("session_index.jsonl"))

        let found = RecentConversationScanner.scan(path: checkout, sources: .init(codex: [configuration.path]))
        #expect(found.map(\.id) == ["named", "unnamed"])
        #expect(found.map(\.title) == ["Review MWAPPS-562", "What does MWAPPS-562 need?"])
        #expect(found.first?.prompt == "What does MWAPPS-562 need?")
        #expect(found.first?.startedAt != nil)
    }

    @Test func openCodeSessionsComeFromItsDatabase() throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("repo").path
        let database = root.appendingPathComponent("opencode.db").path
        let sql = """
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL, title TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, time_archived INTEGER);
        INSERT INTO session VALUES ('ses_a', NULL, '\(checkout)', 'Port the fastboot tool', 1000, 5000, NULL);
        INSERT INTO session VALUES ('ses_b', NULL, '\(checkout)', 'New session - 2026-09-24T13:19:24.332Z', 1000, 4000, NULL);
        INSERT INTO session VALUES ('ses_child', 'ses_a', '\(checkout)', 'Child', 1000, 6000, NULL);
        INSERT INTO session VALUES ('ses_archived', NULL, '\(checkout)', 'Archived', 1000, 7000, 7000);
        INSERT INTO session VALUES ('ses_other', NULL, '\(root.path)', 'Other', 1000, 8000, NULL);
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database, sql]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let found = RecentConversationScanner.scan(path: checkout, sources: .init(openCodeDatabases: [database]))
        #expect(found.map(\.id) == ["ses_a", "ses_b"])
        #expect(found.map(\.title) == ["Port the fastboot tool", "Untitled conversation"])
        #expect(found.first?.updatedAt == Date(timeIntervalSince1970: 5))
    }

    @Test func missingSourcesFindNothing() {
        let found = RecentConversationScanner.scan(path: "/nonexistent/checkout", sources: .init(claude: ["/nonexistent/claude"], codex: ["/nonexistent/codex"], openCodeDatabases: ["/nonexistent/opencode.db"]))
        #expect(found.isEmpty)
    }
}
