import Foundation

/// A navigation target only. URLs never contain a socket, command, or file path.
public struct SessionRoute: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let sessionID: UUID
    public init(projectID: UUID, sessionID: UUID) { self.projectID = projectID; self.sessionID = sessionID }
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "chauffeur", parts.host == "session", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty,
              let projectID = UUID(uuidString: String(path[1])), let sessionID = UUID(uuidString: String(path[2])) else { return nil }
        self.init(projectID: projectID, sessionID: sessionID)
    }
    public var url: URL { URL(string: "chauffeur://session/\(projectID.uuidString)/\(sessionID.uuidString)")! }
}

public enum AttentionReason: String, Codable, Sendable {
    case input, completion, failure, message, result, test
    public var body: String {
        switch self {
        case .input: "This session needs your input."
        case .completion: "This session finished a turn."
        case .failure: "This session failed. Open it to inspect the details."
        case .message: "This session has a new message."
        case .result: "A delegated session reported a result."
        case .test: "This is a test notification. Click to open this session."
        }
    }
}

public struct AttentionNotice: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var route: SessionRoute
    public var reason: AttentionReason
    public var createdAt = Date()
    public init(route: SessionRoute, reason: AttentionReason) { self.route = route; self.reason = reason }
    /// A stable identifier replaces an older alert for the same session, including
    /// a retry after the helper dies between OS acceptance and ledger acknowledgement.
    public var identifier: String { "\(reason == .test ? "test" : "session")-\(route.sessionID.uuidString)" }
}

public struct NotificationDelivery: Codable, Sendable {
    public var notice: AttentionNotice
    public var project: String
    public var session: String
    public init(notice: AttentionNotice, project: String, session: String) {
        self.notice = notice
        self.project = Self.displayName(project)
        self.session = Self.displayName(session)
    }
    private static func displayName(_ text: String) -> String {
        let safe = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(safe)).prefix(120).description
    }
}

public enum NotificationAuthorization: String, Codable, Sendable {
    case unknown, notDetermined, denied, authorized, provisional, unavailable
}

public struct NotificationStatus: Codable, Sendable {
    public var enabled: Bool
    public var authorization: NotificationAuthorization
    public var helperConnected: Bool
    public init(enabled: Bool = false, authorization: NotificationAuthorization = .unknown, helperConnected: Bool = false) {
        self.enabled = enabled; self.authorization = authorization; self.helperConnected = helperConnected
    }
}

public struct NotificationWork: Codable, Sendable {
    public var enabled: Bool
    public var deliveries: [NotificationDelivery]
    public init(enabled: Bool, deliveries: [NotificationDelivery]) { self.enabled = enabled; self.deliveries = deliveries }
}
