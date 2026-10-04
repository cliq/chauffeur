import Foundation

/// The `<scheme>://session/<project-uuid>/<session-uuid>` deep link that reveals a session.
/// A navigation target only: it never carries a socket, command, or file path. The scheme
/// differs per build (`chauffeur` / `chauffeur-debug`), so callers pass the one they accept.
public struct SessionLink: Hashable, Sendable {
    public let projectID: UUID
    public let sessionID: UUID

    public init(projectID: UUID, sessionID: UUID) {
        self.projectID = projectID
        self.sessionID = sessionID
    }

    /// Accepts only host `session` and a path of exactly two UUIDs, with no user, password,
    /// port, query, or fragment.
    public init?(url: URL, scheme: String) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == scheme, parts.host == "session", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty,
              let projectID = UUID(uuidString: String(path[1])), let sessionID = UUID(uuidString: String(path[2])) else { return nil }
        self.init(projectID: projectID, sessionID: sessionID)
    }

    public func url(scheme: String) -> URL {
        URL(string: "\(scheme)://session/\(projectID.uuidString)/\(sessionID.uuidString)")!
    }
}
