import Foundation

/// File types the phone reader knows how to show, by lowercased extension.
public enum DocumentKind: Equatable, Sendable {
    case markdown
    case image
    case text

    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    /// Raster formats UIKit decodes. SVG is text and opens as source.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    public init(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) { self = .markdown }
        else if Self.imageExtensions.contains(ext) { self = .image }
        else { self = .text }
    }
}

public struct SessionDocumentsRequest: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public init(sessionID: UUID) { self.sessionID = sessionID }
}

public enum SessionDocumentSource: String, Codable, Equatable, Sendable, Hashable {
    case mentioned
    case changed
}

public struct SessionDocument: Codable, Equatable, Sendable {
    /// Absolute host path.
    public var path: String
    /// Relative to the session's working directory when inside it, otherwise `~`-abbreviated or absolute.
    public var displayPath: String
    public var sources: Set<SessionDocumentSource>
    public var modifiedAt: Date
    public var size: Int

    public init(path: String, displayPath: String, sources: Set<SessionDocumentSource>, modifiedAt: Date, size: Int) {
        self.path = path; self.displayPath = displayPath; self.sources = sources
        self.modifiedAt = modifiedAt; self.size = size
    }
}

public struct SessionDocumentList: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var documents: [SessionDocument]

    public init(sessionID: UUID, documents: [SessionDocument]) {
        self.sessionID = sessionID; self.documents = documents
    }
}

public struct DocumentReadRequest: Codable, Equatable, Sendable {
    public var sessionID: UUID?
    /// Sent exactly as tapped; the host expands `~` and resolves relative paths.
    public var path: String
    /// The `version` of the last content received; the host answers with `text == nil` when it is unchanged.
    public var knownVersion: String?

    public init(sessionID: UUID?, path: String, knownVersion: String? = nil) {
        self.sessionID = sessionID; self.path = path; self.knownVersion = knownVersion
    }
}

public struct DocumentContent: Codable, Equatable, Sendable {
    public var requestedPath: String
    /// The absolute path the host read.
    public var path: String
    /// Opaque host token, echoed back verbatim as `knownVersion`; never compare it as a date.
    public var version: String
    /// For display only.
    public var modifiedAt: Date
    public var size: Int
    /// `nil` means the file is unchanged since `knownVersion`.
    public var text: String?

    public init(requestedPath: String, path: String, version: String, modifiedAt: Date, size: Int, text: String?) {
        self.requestedPath = requestedPath; self.path = path; self.version = version
        self.modifiedAt = modifiedAt; self.size = size; self.text = text
    }
}

/// Reads part of a binary host file such as an image. Files can exceed one frame, so the phone asks for
/// consecutive chunks; every chunk carries the file's `version` so a file rewritten mid-download is noticed.
public struct DocumentChunkRequest: Codable, Equatable, Sendable {
    /// Raw bytes per chunk; base64 in the JSON envelope keeps it well under the frame limit.
    public static let chunkBytes = 1024 * 1024
    /// The largest file the Mac sends this way.
    public static let maxTotalBytes = 50 * 1024 * 1024

    public var sessionID: UUID?
    /// Sent exactly as tapped; the host expands `~` and resolves relative paths.
    public var path: String
    public var offset: Int64
    /// At offset 0, the host answers with `data == nil` when the file still has this version.
    public var knownVersion: String?

    public init(sessionID: UUID?, path: String, offset: Int64 = 0, knownVersion: String? = nil) {
        self.sessionID = sessionID; self.path = path; self.offset = offset; self.knownVersion = knownVersion
    }
}

public struct DocumentChunk: Codable, Equatable, Sendable {
    public var requestedPath: String
    /// The absolute path the host read.
    public var path: String
    /// Opaque host token, echoed back verbatim as `knownVersion`.
    public var version: String
    public var modifiedAt: Date
    /// Size of the whole file.
    public var size: Int64
    public var offset: Int64
    /// `nil` means the file is unchanged since `knownVersion`.
    public var data: Data?

    public init(requestedPath: String, path: String, version: String, modifiedAt: Date, size: Int64, offset: Int64, data: Data?) {
        self.requestedPath = requestedPath; self.path = path; self.version = version
        self.modifiedAt = modifiedAt; self.size = size; self.offset = offset; self.data = data
    }
}
