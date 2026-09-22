import Foundation
import Darwin

/// Poll by path, rather than holding an inode, because the skill atomically replaces files.
public enum ProgressFiles {
    public static let maximumJSONBytes = 1_048_576

    public static func fileURL(_ path: String) throws -> URL {
        try Validation.absolutePath(path)
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    public static func read(jsonPath: String) throws -> ImplementationProgress {
        let url = try fileURL(jsonPath)
        // Nonblocking open plus fstat avoids hanging on FIFOs or reading device files.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ChauffeurError("progress_unavailable", "Cannot open the progress JSON", path: url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maximumJSONBytes else {
            throw ChauffeurError("progress_invalid", "Progress JSON must be a regular file of at most 1 MiB", path: url.path)
        }
        let data = try handle.read(upToCount: maximumJSONBytes + 1) ?? Data()
        guard data.count <= maximumJSONBytes else { throw ChauffeurError("progress_invalid", "Progress JSON exceeds 1 MiB", path: url.path) }
        do { return try ImplementationProgress.decode(data) }
        catch { throw ChauffeurError("progress_invalid", "Cannot decode the progress JSON; expected implementation-progress schema version 1", path: url.path) }
    }

    public static func htmlURL(_ path: String) throws -> URL {
        let url = try fileURL(path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, ["html", "htm"].contains(url.pathExtension.lowercased()),
              (values.fileSize ?? 0) <= maximumJSONBytes else {
            throw ChauffeurError("progress_invalid", "Progress HTML must be a regular HTML file of at most 1 MiB", path: path)
        }
        return url
    }

    public static func registration(jsonPath: String, htmlPath: String?) throws -> ProgressRegistration {
        _ = try read(jsonPath: jsonPath)
        return try ProgressRegistration(jsonPath: fileURL(jsonPath).path, htmlPath: htmlPath.map { try htmlURL($0).path })
    }
}
