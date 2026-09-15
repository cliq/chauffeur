import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct SnapshotTests {
    private func snapshot(_ id: UUID = UUID(), lines: Int = 300, width: Int = 100) -> TerminalSnapshot {
        TerminalSnapshot(sessionID: id, processID: 42, terminalIdentity: "%1", columns: 100, rows: 30, lineLimit: 10_000,
            history: (0..<lines).map { "line-\($0) " + String(repeating: "界", count: width) + "\n" }.joined(), screen: "\u{1b}[32mCURRENT SCREEN\u{1b}[0m\n")
    }
    private func temporaryRoot() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-snapshots-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    @Test func boundedUnicodeAndSafeTerminalRendering() throws {
        let hostile = "A\u{1b}]52;c;clipboard-secret\u{7}B\u{1b}Pquery-secret\u{1b}\\C\u{9d}hidden-title\u{9c}D\u{1b}[2J\u{1b}[31mred\u{1b}[0m\u{7}"
        #expect(TerminalSnapshot.safeANSI(hostile) == "ABCD\u{1b}[31mred\u{1b}[0m")
        var value = snapshot()
        try value.bound(lines: 100, maximumBytes: 1_048_576)
        #expect(value.history.hasPrefix("line-200 "))
        #expect(value.history.contains("line-299 "))
        #expect(value.history.split(separator: "\n").count == 100)
        #expect(value.truncated)
        value.history = hostile + "\n" + value.history
        try value.bound(lines: 100, maximumBytes: 4096)
        #expect(try JSONCoding.encode(value).count <= 4096)
        #expect(value.history.contains("line-299 "))
        #expect(!value.history.contains("�"))
        #expect(value.rendering.contains("CURRENT SCREEN"))
        #expect(!value.rendering.contains("clipboard-secret"))
        value.version += 1
        #expect(throws: ChauffeurError.self) { try value.validate() }
    }
    @Test func durablePrivateArchivesAndImmediateLineReduction() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SnapshotStore(root: root.appendingPathComponent("snapshots"))
        let value = snapshot()
        let first = try await store.save(value, settings: RetentionSettings(), liveSessions: [value.sessionID])
        var repeated = value; repeated.capturedAt = Date().addingTimeInterval(30)
        let unchanged = try await store.save(repeated, settings: RetentionSettings(), liveSessions: [value.sessionID])
        #expect(unchanged.capturedAt == first.capturedAt)
        let reopened = try SnapshotStore(root: root.appendingPathComponent("snapshots"))
        #expect(try await reopened.read(value.sessionID) == first)
        let path = root.appendingPathComponent("snapshots/\(value.sessionID)/latest.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        var settings = RetentionSettings(); settings.scrollbackLines = 100
        _ = try await reopened.applyRetention(settings: settings, liveSessions: [])
        #expect(try await reopened.read(value.sessionID)?.history.hasPrefix("line-200 ") == true)
        #expect(try await reopened.read(value.sessionID)?.capturedAt == first.capturedAt)
    }
    @Test func globalBudgetEvictsEndedFirstAndPreservesOtherFiles() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SnapshotStore(root: root.appendingPathComponent("snapshots"))
        let native = root.appendingPathComponent("native-conversation.json"), queued = root.appendingPathComponent("queued-message.json")
        for path in [native, queued] { try Data("preserve".utf8).write(to: path) }
        let live = snapshot(lines: 1200), ended = snapshot(lines: 1200)
        _ = try await store.save(live, settings: RetentionSettings(), liveSessions: [live.sessionID])
        _ = try await store.save(ended, settings: RetentionSettings(), liveSessions: [live.sessionID])
        let third = snapshot(lines: 1200)
        _ = try await store.save(third, settings: RetentionSettings(), liveSessions: [live.sessionID, third.sessionID])
        var settings = RetentionSettings(); settings.snapshotBudgetBytes = 1_048_576
        let status = try await store.prune(settings: settings, liveSessions: [live.sessionID, third.sessionID])
        #expect(status.bytes <= settings.snapshotBudgetBytes)
        #expect(status.evictedFiles == 1)
        #expect(try await store.read(ended.sessionID) == nil)
        #expect(try await store.read(live.sessionID) != nil)
        #expect(try await store.read(third.sessionID) != nil)
        for path in [native, queued] { #expect(try String(contentsOf: path, encoding: .utf8) == "preserve") }
    }
    @Test func corruptAndSymlinkedFilesArePreservedAndRejected() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try SnapshotStore(root: root.appendingPathComponent("snapshots"))
        let value = snapshot()
        _ = try await store.save(value, settings: RetentionSettings(), liveSessions: [])
        let path = root.appendingPathComponent("snapshots/\(value.sessionID)/latest.json")
        try Data("invalid JSON".utf8).write(to: path)
        await #expect(throws: ChauffeurError.self) { try await store.read(value.sessionID) }
        await #expect(throws: ChauffeurError.self) { try await store.save(value, settings: RetentionSettings(), liveSessions: []) }
        #expect(try String(contentsOf: path, encoding: .utf8) == "invalid JSON")
        try FileManager.default.removeItem(at: path)
        let outside = root.appendingPathComponent("must-not-create.json")
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        await #expect(throws: ChauffeurError.self) { try await store.save(value, settings: RetentionSettings(), liveSessions: []) }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path.path) == outside.path)
    }
    @Test func processOutputTailKeepsNewestBytesAndSignalsTruncation() async throws {
        let result = try await ProcessRunner.run("/usr/bin/printf", ["oldest\nnewest\n"], outputLimit: 7, keepOutputTail: true)
        #expect(result.output == "newest\n")
        #expect(result.outputTruncated)
        let prefix = try await ProcessRunner.run("/usr/bin/printf", ["oldest\nnewest\n"], outputLimit: 7)
        #expect(prefix.output == "oldest\n")
        #expect(prefix.outputTruncated)
    }
}
