import Foundation

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
