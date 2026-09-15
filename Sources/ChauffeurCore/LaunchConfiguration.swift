import Foundation

/// Only used as a mode-0600, one-shot handoff to the exec helper. Never include
/// this object in diagnostics, session records, IPC responses, or logs.
public struct ExecPayload: Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String
    public init(executable: String, arguments: [String], environment: [String: String], directory: String) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.directory = directory
    }
}

public struct TerminalPacket: Codable, Sendable {
    public var kind: String
    public var bytes: Data?
    public var message: String?
    public var version = WireProtocol.major
    public init(kind: String, bytes: Data? = nil, message: String? = nil) { self.kind = kind; self.bytes = bytes; self.message = message }
}

public struct LaunchRequest: Codable, Sendable {
    public var projectID: UUID
    public var groupID: UUID
    public var presetID: UUID
    public var folderID: UUID
    public var worktreeID: UUID?
    public var additionalFolderIDs: [UUID]
    public var title: String
    public var task: String?
    public var allowSharedCheckout: Bool
    public var coordinationEnabled: Bool
    public var retryKey: UUID
    public init(projectID: UUID, groupID: UUID, presetID: UUID, folderID: UUID, title: String, worktreeID: UUID? = nil, additionalFolderIDs: [UUID] = [], task: String? = nil, allowSharedCheckout: Bool = false, coordinationEnabled: Bool = true, retryKey: UUID = UUID()) {
        self.projectID = projectID; self.groupID = groupID; self.presetID = presetID; self.folderID = folderID; self.title = title
        self.worktreeID = worktreeID; self.additionalFolderIDs = additionalFolderIDs; self.task = task
        self.allowSharedCheckout = allowSharedCheckout; self.coordinationEnabled = coordinationEnabled; self.retryKey = retryKey
    }
}

public struct WorktreeCreationRequest: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var folderID: UUID
    public var branch: String
    public var baseRef: String
    public var retryKey: UUID?
    public init(projectID: UUID, folderID: UUID, branch: String, baseRef: String, retryKey: UUID? = UUID()) {
        self.projectID = projectID; self.folderID = folderID
        self.branch = branch; self.baseRef = baseRef; self.retryKey = retryKey
    }
}
