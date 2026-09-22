import Foundation

/// Only used as a mode-0600, one-shot handoff to the exec helper. Never include
/// this object in diagnostics, session records, IPC responses, or logs.
public struct ExecPayload: Codable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: String
    /// A line the exec helper prints to the terminal before starting the process, so the user sees
    /// what was applied (for example the `export` command for agent configuration directories).
    public var preamble: String?
    public init(executable: String, arguments: [String], environment: [String: String], directory: String, preamble: String? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.directory = directory; self.preamble = preamble
    }
}

public struct TerminalPacket: Codable, Sendable {
    public var kind: String
    public var bytes: Data?
    public var message: String?
    public var version = WireProtocol.major
    public init(kind: String, bytes: Data? = nil, message: String? = nil) { self.kind = kind; self.bytes = bytes; self.message = message }
}

/// Whether a session's terminal is waiting at its own prompt, with the name of
/// the foreground command when something else is running in it.
public struct TerminalActivity: Codable, Sendable {
    public var idle: Bool
    public var command: String?
    public init(idle: Bool, command: String?) { self.idle = idle; self.command = command }
}

public enum LaunchKind: String, Codable, Sendable { case agent, shell }

public struct LaunchRequest: Codable, Sendable {
    public var projectID: UUID
    public var groupID: UUID
    /// Ignored for shell launches, which synthesize their own preset.
    public var presetID: UUID
    public var folderID: UUID
    public var worktreeID: UUID?
    public var additionalFolderIDs: [UUID]
    public var title: String
    public var task: String?
    public var allowSharedCheckout: Bool
    /// Chauffeur messaging and delegation are experimental, so launches opt in
    /// explicitly. Callers that omit a choice get basic terminal mode.
    public var coordinationEnabled: Bool
    public var retryKey: UUID
    /// Missing in requests from older clients, which only launch agents.
    public var kind: LaunchKind?
    /// nil inherits the preset; an empty string explicitly selects the provider default.
    public var modelOverride: String?
    /// nil inherits the preset; an empty string explicitly selects the provider default.
    public var reasoningOverride: String?
    public var launchKind: LaunchKind { kind ?? .agent }
    public init(projectID: UUID, groupID: UUID, presetID: UUID, folderID: UUID, title: String, worktreeID: UUID? = nil, additionalFolderIDs: [UUID] = [], task: String? = nil, allowSharedCheckout: Bool = false, coordinationEnabled: Bool = false, retryKey: UUID = UUID(), kind: LaunchKind? = nil, modelOverride: String? = nil, reasoningOverride: String? = nil) {
        self.projectID = projectID; self.groupID = groupID; self.presetID = presetID; self.folderID = folderID; self.title = title
        self.worktreeID = worktreeID; self.additionalFolderIDs = additionalFolderIDs; self.task = task
        self.allowSharedCheckout = allowSharedCheckout; self.coordinationEnabled = coordinationEnabled; self.retryKey = retryKey
        self.kind = kind
        self.modelOverride = modelOverride; self.reasoningOverride = reasoningOverride
    }
    /// A login shell in the selected checkout. The preset ID is a placeholder.
    public static func shell(projectID: UUID, groupID: UUID, folderID: UUID, title: String, worktreeID: UUID? = nil, retryKey: UUID = UUID()) -> LaunchRequest {
        LaunchRequest(projectID: projectID, groupID: groupID, presetID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, folderID: folderID, title: title, worktreeID: worktreeID, allowSharedCheckout: true, coordinationEnabled: false, retryKey: retryKey, kind: .shell)
    }
}

public enum WorktreeBranchName {
    public static func suggested(from title: String) -> String {
        // Reuse directory slugging, but do not invent a branch for an empty title.
        guard title.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { return "" }
        return Paths.slug(title).lowercased()
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
