import Foundation
import Darwin
import ChauffeurCore

/// Bounded, private JSONL with a schema that has no arbitrary text fields.
/// Logging is best-effort; a full disk or unsafe file must not stop an agent.
public final class RuntimeLogStore: @unchecked Sendable {
    public static let maximumFileBytes = 512 * 1024
    private let directory: Int32
    private let lockFile: Int32
    private let mutex = NSLock()
    private var writeFailed = false
    private let maximumBytes: Int
    private static let names = ["runtime.jsonl", "runtime.1.jsonl", "runtime.2.jsonl", "runtime.3.jsonl"]

    public static func directory(for dataRoot: URL) -> URL {
        if Paths.canonical(dataRoot.path) == Paths.canonical(Paths.applicationSupport.path) {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(AppBuild.current.displayName)")
        }
        return dataRoot.appendingPathComponent("runtime/logs")
    }
    public init(root: URL, maximumBytes: Int = RuntimeLogStore.maximumFileBytes) throws {
        self.maximumBytes = min(Self.maximumFileBytes, max(1024, maximumBytes))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.failure }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), fchmod(directory, 0o700) == 0 else { Darwin.close(directory); throw Self.failure }
        self.directory = directory
        do { lockFile = try Self.openFile(directory: directory, name: ".runtime-log.lock", flags: O_RDWR | O_CREAT) }
        catch { Darwin.close(directory); throw error }
    }
    deinit { Darwin.close(lockFile); Darwin.close(directory) }
    private static var failure: ChauffeurError { ChauffeurError("log_unavailable", "Structured runtime logs are unavailable") }
    private static func openFile(directory: Int32, name: String, flags: Int32) throws -> Int32 {
        let fd = openat(directory, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw failure }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else { Darwin.close(fd); throw failure }
        return fd
    }
    private func fileInfo(_ name: String) throws -> stat? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw Self.failure
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw Self.failure }
        return info
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        // Startup diagnostics from another process must never block launch or
        // interleave with rotation. Contention is surfaced as unavailable.
        guard flock(lockFile, LOCK_EX | LOCK_NB) == 0 else { throw Self.failure }
        defer { _ = flock(lockFile, LOCK_UN) }
        return try body()
    }
    public func append(_ entry: RuntimeLogEntry) {
        do {
            try locked {
                let encoder = JSONCoding.encoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var line = try encoder.encode(entry); line.append(0x0a)
                guard entry.schemaVersion == 1, line.count <= 8192, line.count <= maximumBytes else { throw Self.failure }
                // Validate every managed destination before deleting or renaming.
                let inventory = try Self.names.map { try fileInfo($0) }
                guard inventory.allSatisfy({ ($0?.st_size ?? 0) <= maximumBytes }) else { throw Self.failure }
                if (inventory[0]?.st_size ?? 0) + Int64(line.count) > maximumBytes {
                    if inventory[3] != nil, unlinkat(directory, Self.names[3], 0) != 0 { throw Self.failure }
                    for index in stride(from: 2, through: 0, by: -1) where inventory[index] != nil {
                        guard renameat(directory, Self.names[index], directory, Self.names[index + 1]) == 0 else { throw Self.failure }
                    }
                }
                let fd = try Self.openFile(directory: directory, name: Self.names[0], flags: O_WRONLY | O_APPEND | O_CREAT)
                defer { Darwin.close(fd) }
                try line.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw Self.failure }
                        offset += count
                    }
                }
                writeFailed = false
            }
        } catch { mutex.withLock { writeFailed = true } }
    }
    public func recent(limit: Int = 200) -> DiagnosticLogs {
        do {
            return try locked {
                var result = DiagnosticLogs(status: writeFailed ? .unavailable : .available)
                let limit = min(200, max(0, limit))
                for name in Self.names.reversed() {
                    guard let info = try fileInfo(name) else { continue }
                    guard info.st_size <= maximumBytes else { result.status = .unavailable; continue }
                    let fd = try Self.openFile(directory: directory, name: name, flags: O_RDONLY)
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                    try handle.close()
                    guard data.count <= maximumBytes else { result.status = .unavailable; continue }
                    for line in data.split(separator: 0x0a) {
                        guard line.count <= 8192, let entry = try? JSONCoding.decode(RuntimeLogEntry.self, from: Data(line)), entry.schemaVersion == 1 else { result.discardedLines += 1; continue }
                        result.entries.append(entry)
                        if result.entries.count > limit { result.entries.removeFirst(result.entries.count - limit) }
                    }
                }
                return result
            }
        } catch { return DiagnosticLogs(status: .unavailable) }
    }
}
