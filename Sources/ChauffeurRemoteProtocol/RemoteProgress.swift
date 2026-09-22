import Foundation

public struct SessionProgressSummary: Codable, Equatable, Sendable {
    public var title: String
    public var now: String
    public var percentComplete: Int?
    public var updatedAt: Date?
    public var error: String?

    public init(title: String, now: String, percentComplete: Int? = nil, updatedAt: Date? = nil, error: String? = nil) {
        self.title = title; self.now = now; self.percentComplete = percentComplete
        self.updatedAt = updatedAt; self.error = error
    }
}

public struct SessionProgressRequest: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public init(sessionID: UUID) { self.sessionID = sessionID }
}

/// Only the registered panel and its JSON are transferred, never arbitrary host paths.
public struct SessionProgressPanel: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var summary: SessionProgressSummary
    public var json: String
    public var html: String?
    public var htmlError: String?

    public init(sessionID: UUID, summary: SessionProgressSummary, json: String, html: String? = nil, htmlError: String? = nil) {
        self.sessionID = sessionID; self.summary = summary; self.json = json
        self.html = html; self.htmlError = htmlError
    }
}
