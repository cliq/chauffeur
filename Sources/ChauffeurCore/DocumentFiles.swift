import Foundation
#if canImport(Darwin)
import Darwin
/// `stat` alone would name `DocumentFiles.stat(path:)` inside the enum.
private typealias FileStatus = Darwin.stat
#else
import Glibc
private typealias FileStatus = Glibc.stat
#endif

/// Guarded reads of host documents. Any readable file may be read, but only regular UTF-8 files up to `maximumBytes`.
public enum DocumentFiles {
    public static let maximumBytes = 2 * 1_048_576

    public struct DocumentStat: Equatable, Sendable {
        /// Opaque token built from the same `fstat`: mtime ns, ctime ns, inode, size.
        public var version: String
        public var modifiedAt: Date
        public var size: Int
    }

    public static func stat(path: String, limit: Int = maximumBytes) throws -> DocumentStat {
        let (handle, info, _) = try open(path, limit: limit)
        defer { try? handle.close() }
        return documentStat(info)
    }

    public static func read(path: String) throws -> (text: String, stat: DocumentStat) {
        let (handle, info, url) = try open(path)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw tooLarge(url.path, limit: maximumBytes) }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ChauffeurError("document_not_text", "The document is not valid UTF-8 text", path: url.path)
        }
        return (text, documentStat(info))
    }

    /// Up to `length` bytes starting at `offset` of a regular file no larger than `limit`, for binary files sent in chunks.
    public static func readChunk(path: String, offset: Int64, length: Int, limit: Int) throws -> (data: Data, stat: DocumentStat) {
        let (handle, info, url) = try open(path, limit: limit)
        defer { try? handle.close() }
        guard offset >= 0, offset <= Int64(info.st_size) else { throw changed(url.path) }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: max(0, length)) ?? Data()
        // A file rewritten in place during the read could mix two versions under the old version token.
        var after = FileStatus()
        let stat = documentStat(info)
        guard fstat(handle.fileDescriptor, &after) == 0, documentStat(after).version == stat.version else {
            throw changed(url.path)
        }
        return (data, stat)
    }

    /// Expands `~`, joins relative paths onto `workingDirectory` (falling back to each additional path that has the file),
    /// and standardizes. When nothing exists the working-directory join is returned so errors name it.
    public static func resolve(_ path: String, workingDirectory: String?, additionalPaths: [String]) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        }
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        var bases = [String]()
        if let workingDirectory, !workingDirectory.isEmpty { bases.append(workingDirectory) }
        bases += additionalPaths
        let candidates = bases.map { (($0 as NSString).appendingPathComponent(path) as NSString).standardizingPath }
        guard let first = candidates.first else { return (path as NSString).standardizingPath }
        if workingDirectory?.isEmpty == false, FileManager.default.fileExists(atPath: first) { return first }
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? first
    }

    private static func open(_ path: String, limit: Int = maximumBytes) throws -> (FileHandle, FileStatus, URL) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Nonblocking open plus fstat avoids hanging on FIFOs or reading device files.
        let descriptor = POSIX.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ChauffeurError("document_not_found", "Cannot open the document", path: url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = FileStatus()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            try? handle.close()
            throw ChauffeurError("document_not_regular_file", "The path is not a regular file", path: url.path)
        }
        guard info.st_size <= limit else {
            try? handle.close()
            throw tooLarge(url.path, limit: limit)
        }
        return (handle, info, url)
    }

    private static func changed(_ path: String) -> ChauffeurError {
        ChauffeurError("document_changed", "The document changed while it was being read", path: path)
    }

    private static func tooLarge(_ path: String, limit: Int) -> ChauffeurError {
        ChauffeurError("document_too_large", "The document is larger than \(limit / 1_048_576) MiB", path: path)
    }

    private static func documentStat(_ info: FileStatus) -> DocumentStat {
        #if os(Linux)
        let mtime = info.st_mtim, ctime = info.st_ctim
        #else
        let mtime = info.st_mtimespec, ctime = info.st_ctimespec
        #endif
        let modified = Date(timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1_000_000_000)
        func nanoseconds(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }
        return DocumentStat(version: "\(nanoseconds(mtime))-\(nanoseconds(ctime))-\(info.st_ino)-\(info.st_size)", modifiedAt: modified, size: Int(info.st_size))
    }
}
