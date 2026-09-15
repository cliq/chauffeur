import Foundation
import Darwin
import ChauffeurCore

/// Owns only runtime/snapshots/<session UUID>/latest.json. No provider paths or
/// ledger files are accepted by this API or visited during cleanup.
public actor SnapshotStore {
    public let root: URL
    private let manager = FileManager.default
    private var evictedFiles = 0
    public init(root: URL) throws {
        self.root = root
        if !Self.exists(root) { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try Self.requireDirectory(root)
    }
    private static func exists(_ path: URL) -> Bool { var info = stat(); return lstat(path.path, &info) == 0 }
    private static func requireDirectory(_ path: URL) throws {
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true && values.isSymbolicLink != true else { throw ChauffeurError("snapshot_path", "Snapshot directory must be a real directory", path: path.path) }
    }
    private func file(_ id: UUID, create: Bool = false) throws -> URL {
        try Self.requireDirectory(root)
        let directory = root.appendingPathComponent(id.uuidString)
        if create && !Self.exists(directory) { try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try Self.requireDirectory(directory)
        let file = directory.appendingPathComponent("latest.json")
        if Self.exists(file) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true && values.isSymbolicLink != true else { throw ChauffeurError("snapshot_path", "Snapshot must be a regular file", path: file.path) }
            guard (values.fileSize ?? 0) <= TerminalSnapshot.maximumFileBytes else { throw ChauffeurError("invalid_snapshot", "Saved terminal history exceeds its size limit", path: file.path) }
        }
        return file
    }
    public func read(_ id: UUID) throws -> TerminalSnapshot? {
        guard Self.exists(root.appendingPathComponent(id.uuidString)) else { return nil }
        let path = try file(id)
        guard manager.fileExists(atPath: path.path) else { return nil }
        do {
            let value = try JSONCoding.decode(TerminalSnapshot.self, from: Data(contentsOf: path))
            try value.validate()
            guard value.sessionID == id else { throw ChauffeurError("invalid_snapshot", "Saved history belongs to another session") }
            return value
        } catch { throw ChauffeurError("invalid_snapshot", "Cannot read saved terminal history; the file is preserved", path: path.path) }
    }
    @discardableResult public func save(_ snapshot: TerminalSnapshot, settings: RetentionSettings, liveSessions: Set<UUID>) throws -> TerminalSnapshot {
        try settings.validate()
        var value = snapshot
        try value.bound(lines: settings.scrollbackLines, maximumBytes: settings.snapshotBudgetBytes)
        let path = try file(value.sessionID, create: true)
        if let existing = try read(value.sessionID) {
            var comparable = value; comparable.capturedAt = existing.capturedAt
            if comparable == existing { _ = try prune(settings: settings, liveSessions: liveSessions); return existing }
        }
        let data = try JSONCoding.encode(value)
        try data.write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        _ = try prune(settings: settings, liveSessions: liveSessions)
        // Match the persisted date precision on both initial and deduplicated reads.
        return try JSONCoding.decode(TerminalSnapshot.self, from: data)
    }
    private struct Entry { var id: UUID; var path: URL; var bytes: Int; var modified: Date }
    private func entries() throws -> [Entry] {
        try Self.requireDirectory(root)
        var result: [Entry] = []
        for directory in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let path = try file(id)
            guard manager.fileExists(atPath: path.path) else { continue }
            let values = try path.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            result.append(Entry(id: id, path: path, bytes: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast))
        }
        return result
    }
    public func status(budgetBytes: Int) throws -> SnapshotStorageStatus {
        let values = try entries()
        return SnapshotStorageStatus(files: values.count, bytes: values.reduce(0) { $0 + $1.bytes }, budgetBytes: budgetBytes, evictedFiles: evictedFiles)
    }
    /// Apply a reduced line limit to completed archives as well as live captures.
    @discardableResult public func applyRetention(settings: RetentionSettings, liveSessions: Set<UUID>) throws -> SnapshotStorageStatus {
        try settings.validate()
        for entry in try entries() {
            guard var value = try read(entry.id) else { continue }
            let original = value
            try value.bound(lines: settings.scrollbackLines, maximumBytes: settings.snapshotBudgetBytes)
            if value != original {
                try JSONCoding.encode(value).write(to: entry.path, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600, .modificationDate: entry.modified], ofItemAtPath: entry.path.path)
            }
        }
        return try prune(settings: settings, liveSessions: liveSessions)
    }
    @discardableResult public func prune(settings: RetentionSettings, liveSessions: Set<UUID>) throws -> SnapshotStorageStatus {
        try settings.validate()
        let values = try entries().sorted {
            if liveSessions.contains($0.id) != liveSessions.contains($1.id) { return !liveSessions.contains($0.id) }
            return $0.modified < $1.modified
        }
        var remaining = values.reduce(0) { $0 + $1.bytes }, files = values.count
        for entry in values where remaining > settings.snapshotBudgetBytes {
            try manager.removeItem(at: entry.path) // Delete only our named file, never a directory tree.
            remaining -= entry.bytes; files -= 1; evictedFiles += 1
        }
        return SnapshotStorageStatus(files: files, bytes: remaining, budgetBytes: settings.snapshotBudgetBytes, evictedFiles: evictedFiles)
    }
}
