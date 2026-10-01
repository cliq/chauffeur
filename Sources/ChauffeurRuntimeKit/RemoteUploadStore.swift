import Foundation
import ChauffeurCore
import ChauffeurRemoteProtocol

/// Receives files the phone sends in chunks and keeps each finished file in its own folder
/// under a temporary directory, so the phone can paste its path into a terminal. Only the
/// device that started an upload can continue it. Unfinished uploads expire after ten minutes
/// and finished files after a week.
public actor RemoteUploadStore {
    private struct Pending {
        let deviceID: UUID
        let filename: String
        let totalBytes: Int64
        let partURL: URL
        var receivedBytes: Int64
        var lastChunk: Date
    }

    private let root: URL
    private var pending: [UUID: Pending] = [:]
    private var finished: [UUID: String] = [:]

    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-uploads", isDirectory: true)) {
        self.root = root
    }

    public func receive(_ chunk: UploadFileChunkRequest, deviceID: UUID) throws -> UploadedFileStatus {
        if let path = finished[chunk.uploadID] {
            // A retry of the last chunk after its response was lost.
            return UploadedFileStatus(uploadID: chunk.uploadID, receivedBytes: chunk.totalBytes, path: path)
        }
        let name = try Self.safeFilename(chunk.filename)
        try Validation.require(chunk.totalBytes > 0 && chunk.totalBytes <= UploadFileChunkRequest.maxTotalBytes,
                               "Files must be between 1 byte and \(UploadFileChunkRequest.maxTotalBytes / 1_048_576) MB")
        try Validation.require(!chunk.data.isEmpty && chunk.data.count <= UploadFileChunkRequest.chunkBytes, "Each upload chunk must hold 1 byte to 1 MB")
        var upload: Pending
        if let existing = pending[chunk.uploadID] {
            guard existing.deviceID == deviceID, existing.filename == name, existing.totalBytes == chunk.totalBytes else {
                throw ChauffeurError("upload_conflict", "This upload ID is already used for a different file")
            }
            upload = existing
        } else {
            guard chunk.offset == 0 else {
                throw ChauffeurError("upload_unknown", "The Mac no longer has the start of this upload. Send the file again")
            }
            try prune()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let partURL = root.appendingPathComponent("\(chunk.uploadID.uuidString).part")
            guard FileManager.default.createFile(atPath: partURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ChauffeurError("upload_failed", "The Mac could not create the upload", path: partURL.path)
            }
            upload = Pending(deviceID: deviceID, filename: name, totalBytes: chunk.totalBytes, partURL: partURL, receivedBytes: 0, lastChunk: Date())
        }
        let end = chunk.offset + Int64(chunk.data.count)
        if end <= upload.receivedBytes {
            // Already written: a retry of a chunk whose response was lost.
        } else {
            guard chunk.offset == upload.receivedBytes, end <= upload.totalBytes else {
                throw ChauffeurError("upload_offset", "The Mac expected this upload to continue at byte \(upload.receivedBytes). Send the file again")
            }
            let handle = try FileHandle(forWritingTo: upload.partURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk.data)
            upload.receivedBytes = end
        }
        upload.lastChunk = Date()
        guard upload.receivedBytes == upload.totalBytes else {
            pending[chunk.uploadID] = upload
            return UploadedFileStatus(uploadID: chunk.uploadID, receivedBytes: upload.receivedBytes)
        }
        pending[chunk.uploadID] = nil
        // Each upload gets its own folder so the original name survives without collisions.
        let folder = root.appendingPathComponent(String(chunk.uploadID.uuidString.prefix(8)).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: upload.partURL, to: destination)
        let path = Paths.canonical(destination.path)
        finished[chunk.uploadID] = path
        return UploadedFileStatus(uploadID: chunk.uploadID, receivedBytes: upload.totalBytes, path: path)
    }

    /// A name that needs no quoting when pasted into a shell or an agent's prompt.
    static func safeFilename(_ name: String) throws -> String {
        // Only the last component counts; `URL` would resolve `..` against the working directory.
        let base = name.split(separator: "/").last.map(String.init) ?? ""
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var cleaned = String(base.map { allowed.contains($0) ? $0 : "-" })
        while cleaned.contains("--") { cleaned = cleaned.replacingOccurrences(of: "--", with: "-") }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        try Validation.require(!cleaned.isEmpty, "The file needs a name")
        return String(cleaned.suffix(120))
    }

    private func prune() throws {
        let now = Date()
        for (id, upload) in pending where now.timeIntervalSince(upload.lastChunk) > 600 {
            try? FileManager.default.removeItem(at: upload.partURL)
            pending[id] = nil
        }
        guard let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        for item in folders where item.pathExtension != "part" {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if modified < cutoff { try? FileManager.default.removeItem(at: item) }
        }
        finished = finished.filter { FileManager.default.fileExists(atPath: $0.value) }
    }
}
