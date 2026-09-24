import Foundation

public protocol Record: Codable, Identifiable, Sendable where ID == UUID {
    var id: UUID { get }
    func validate() throws
}

public enum CLIKind: String, Codable, CaseIterable, Sendable {
    case codex, claude, opencode
    /// A plain login shell in a checkout. Never stored in a preset set; the
    /// runtime synthesizes its preset when launching a shell session.
    case shell
    public var isAgent: Bool { self != .shell }
    public var displayName: String { provider?.displayName ?? "Shell" }
}
public enum SidebarMode: String, Codable, Sendable { case repositories, sessions }
public enum Availability: String, Codable, Sendable { case available, missing, inaccessible }
public enum IntegrationState: String, Codable, Sendable { case unverified, supported, unavailable }

public struct PresetSet: Record, Equatable {
    public var id = UUID()
    public var name: String
    public var agentSelection: AgentSelection?
    public var customAgentsInitialized: Bool?
    public var configurationDirectories: [String: String]?
    public var revision = 1
    public var archived = false
    /// The default team: preselected for new projects and used when nothing names a team.
    /// The runtime keeps exactly one non-archived team flagged whenever any exists.
    public var isDefault = false
    public init(name: String, agentSelection: AgentSelection? = nil) {
        self.name = name; self.agentSelection = agentSelection
        self.configurationDirectories = agentSelection == nil ? nil : [:]
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        customAgentsInitialized = try container.decodeIfPresent(Bool.self, forKey: .customAgentsInitialized)
        agentSelection = try container.decodeIfPresent(AgentSelection.self, forKey: .agentSelection)
        configurationDirectories = try container.decodeIfPresent([String: String].self, forKey: .configurationDirectories)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
    public func validate() throws {
        try Validation.name(name)
        for (kind, path) in configurationDirectories ?? [:] {
            try Validation.require(CLIKind(rawValue: kind)?.provider != nil, "Unknown agent")
            if !path.isEmpty { try Validation.absolutePath(path) }
        }
        try Validation.require(revision > 0, "Revision must be positive")
        try Validation.require(!(isDefault && archived), "The default team cannot be archived")
    }
}

public struct AgentPreset: Record, Equatable {
    public var id = UUID()
    public var setID: UUID
    public var name: String
    public var kind: CLIKind
    public var executable: String
    /// Legacy on-disk field; resolved from the team for new-format definitions.
    public var configurationDirectory: String
    public var sourceBaseID: UUID?
    public var baseRevision: Int?
    public var arguments: [String] = []
    /// Authoritative editable text when present. Legacy records use `arguments`.
    public var rawArguments: String?
    public var integration: IntegrationState = .unverified
    public var archived = false
    public init(setID: UUID, name: String, kind: CLIKind, executable: String, configurationDirectory: String) {
        self.setID = setID; self.name = name; self.kind = kind
        self.executable = executable; self.configurationDirectory = configurationDirectory
    }
    public func validate() throws {
        try Validation.name(name)
        try Validation.require(!executable.isEmpty && !executable.contains("\0"), "Select an executable")
        if !configurationDirectory.isEmpty { try Validation.absolutePath(configurationDirectory) }
        if rawArguments == nil { try LaunchPolicy.validateArguments(arguments, kind: kind) }
    }
}

public struct ProjectFolder: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var selectedPath: String
    public var canonicalPath: String
    public var availability: Availability = .available
    public var repositoryID: UUID?
    public var registered = true
    public init(path: String, name: String? = nil) {
        self.selectedPath = path; self.canonicalPath = Paths.canonical(path)
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
    }
}

public struct AgentGroup: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var isDefault = false
    public var archived = false
    public var createdAt = Date()
    public var updatedAt = Date()
    public init(name: String, isDefault: Bool = false) { self.name = name; self.isDefault = isDefault }
}

public struct Project: Record, Equatable {
    public var id = UUID()
    public var name: String
    public var presetSetID: UUID
    public var discoveryFolder: String?
    public var folders: [ProjectFolder] = []
    public var groups = [AgentGroup(name: "Default", isDefault: true)]
    public var archived = false
    public var createdAt = Date()
    public var updatedAt = Date()
    public var lastOpenedAt = Date()
    public var lastPresetID: UUID?
    public init(name: String, presetSetID: UUID) { self.name = name; self.presetSetID = presetSetID }
    public mutating func addFolder(_ folder: ProjectFolder) {
        if let index = folders.firstIndex(where: { $0.canonicalPath == folder.canonicalPath }) { folders[index].registered = true }
        else { folders.append(folder) }
    }
    public func validate() throws {
        try Validation.name(name)
        try Validation.require(groups.filter(\.isDefault).count == 1, "Project must have exactly one Default group")
        try Validation.require(!groups.contains { $0.isDefault && $0.archived }, "Default group cannot be archived")
        try Validation.unique(groups.map(\.id), field: "group ID")
        try Validation.unique(folders.map(\.id), field: "folder ID")
        try Validation.unique(folders.filter(\.registered).map(\.canonicalPath), field: "canonical folder path")
        for group in groups { try Validation.name(group.name) }
        for folder in folders { try Validation.absolutePath(folder.selectedPath); try Validation.absolutePath(folder.canonicalPath) }
    }
}

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case starting, running, needsAttention, turnFinished, exited, failed, interrupted, activityUnknown
    public var label: String {
        switch self {
        case .starting: "Starting"
        case .running: "Running"
        case .needsAttention: "Needs attention"
        case .turnFinished: "Turn finished"
        case .exited: "Exited"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        case .activityUnknown: "Activity unknown"
        }
    }
    public var isLive: Bool { [.starting, .running, .needsAttention, .turnFinished, .activityUnknown].contains(self) }
}

public struct CheckoutIdentity: Codable, Equatable, Sendable {
    public var path: String
    public var directoryIdentity: UUID
    public var gitIdentity: UUID?
    public init(path: String, directoryIdentity: UUID, gitIdentity: UUID?) {
        self.path = path; self.directoryIdentity = directoryIdentity; self.gitIdentity = gitIdentity
    }
}

public struct LaunchSnapshot: Codable, Equatable, Sendable {
    public var preset: AgentPreset
    public var teamID: UUID?
    public var configurationEnvironment: [String: String]?
    public var configurationUsesDefault: Bool?
    public var presetSetName: String
    public var presetSetRevision: Int
    public var executablePath: String
    public var executableVersion: String
    public var configurationPath: String
    public var workingDirectory: String
    public var additionalPaths: [String]
    public var resolvedArguments: [String]?
    public var selectedModel: String?
    public var selectedReasoning: String?
    public var executionPolicy: WorkerExecutionPolicy?
    public var gitWorktreeIdentities: [UUID]?
    public var checkoutIdentities: [CheckoutIdentity]?
    public var launchedAt = Date()
    public init(preset: AgentPreset, set: PresetSet, executablePath: String, executableVersion: String, workingDirectory: String, additionalPaths: [String]) {
        self.teamID = set.id
        self.preset = preset; self.presetSetName = set.name; self.presetSetRevision = set.revision
        self.executablePath = executablePath; self.executableVersion = executableVersion
        self.configurationPath = Paths.canonical(preset.configurationDirectory)
        self.workingDirectory = workingDirectory; self.additionalPaths = additionalPaths
    }
}

public struct Session: Record, Equatable {
    public var id = UUID()
    public var projectID: UUID
    public var groupID: UUID
    public var title: String
    public var launch: LaunchSnapshot
    public var folderID: UUID
    public var worktreeID: UUID?
    public var state: SessionState = .starting
    public var processID: Int32?
    public var runtimeID: UUID?
    public var terminalIdentity: String?
    public var nativeConversationID: String?
    /// Set when `/resume` adopted a conversation another live session also uses.
    public var conversationWarning: String?
    /// Native hooks deliver inbox reminders to this coordinated session. False
    /// when Codex hook trust could not be established; nil without coordination.
    public var inboxReminders: Bool?
    /// Set while a live session's executable no longer exists, for example after a
    /// Homebrew upgrade removed the version it started from.
    public var executableWarning: String?
    /// Set while the turn has ended but this session still waits on background work.
    public var waiting: SessionWait?
    public var parentID: UUID?
    public var delegationID: UUID?
    public var historyProtected: Bool?
    public var progress: ProgressRegistration?
    public var closureOutcome: String?
    public var closureReason: String?
    public var closedAt: Date?
    public var initialTask: String?
    public var launchRequestFingerprint: String?
    public var error: String?
    public var failureCode: String?
    public var exitStatus: Int32?
    public var unread = false
    public var pendingMessages = 0
    public var createdAt = Date()
    public var updatedAt = Date()
    /// Launched with Chauffeur's MCP server and lifecycle hooks, not basic terminal mode.
    public var coordinationEnabled: Bool { launch.preset.kind.isAgent && launch.preset.integration != .unavailable }
    public var needsAttention: Bool { pendingMessages > 0 || state == .needsAttention || state == .failed || (state == .turnFinished && unread) }
    public init(projectID: UUID, groupID: UUID, title: String, launch: LaunchSnapshot, folderID: UUID) {
        self.projectID = projectID; self.groupID = groupID; self.title = title; self.launch = launch; self.folderID = folderID
    }
    public func validate() throws {
        try Validation.name(title); try Validation.absolutePath(launch.configurationPath)
        try Validation.absolutePath(launch.workingDirectory)
        if let nativeConversationID { try Validation.require(UUID(uuidString: nativeConversationID) != nil, "Native conversation ID must be a UUID") }
        if let progress {
            try Validation.absolutePath(progress.jsonPath)
            if let htmlPath = progress.htmlPath { try Validation.absolutePath(htmlPath) }
        }
    }
}

public struct Worktree: Record, Equatable {
    public var id = UUID()
    public var projectID: UUID
    public var folderID: UUID
    public var repositoryID: UUID
    // Missing in records whose repository ID was derived from its old path.
    public var repositoryIdentityVersion: Int?
    public var path: String
    public var repositoryPath: String
    public var branch: String
    public var baseCommit: String
    /// The branch the worktree was created from, when the base ref named one.
    /// Unmerged-commit counts are measured against it.
    public var baseBranch: String?
    public var managed: Bool
    public var creationRequestFingerprint: String?
    public var gitIdentity: UUID?
    public var availability: Availability = .available
    public var registered = true
    public init(projectID: UUID, folderID: UUID, repositoryID: UUID, path: String, repositoryPath: String, branch: String, baseCommit: String, managed: Bool) {
        self.projectID = projectID; self.folderID = folderID; self.repositoryID = repositoryID
        self.repositoryIdentityVersion = 1
        self.path = path; self.repositoryPath = repositoryPath; self.branch = branch; self.baseCommit = baseCommit; self.managed = managed
    }
    public func validate() throws { try Validation.absolutePath(path); try Validation.absolutePath(repositoryPath) }
}

public struct WindowState: Record, Equatable {
    public var id: UUID // project ID
    public var frame: String?
    public var displayID: String?
    public var selectedGroupID: UUID?
    public var selectedSessionID: UUID?
    /// Selected repository folder and checkout path. A `nil` path with a folder
    /// selects the repository overview; the main checkout uses the folder path.
    public var selectedFolderID: UUID?
    public var selectedWorktreePath: String?
    public var sidebarMode: SidebarMode = .repositories
    /// User ordering of session tabs; each checkout displays its matching subset.
    public var sessionTabOrder: [UUID] = []
    /// Legacy tab layout fields. Older records still carry them; new writes
    /// leave them empty.
    public var tabs: [UUID] = []
    public var splitSessionID: UUID?
    public var sidebarVisible = true
    public var wasOpen = false
    public init(projectID: UUID) { id = projectID }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        frame = try container.decodeIfPresent(String.self, forKey: .frame)
        displayID = try container.decodeIfPresent(String.self, forKey: .displayID)
        selectedGroupID = try container.decodeIfPresent(UUID.self, forKey: .selectedGroupID)
        selectedSessionID = try container.decodeIfPresent(UUID.self, forKey: .selectedSessionID)
        selectedFolderID = try container.decodeIfPresent(UUID.self, forKey: .selectedFolderID)
        selectedWorktreePath = try container.decodeIfPresent(String.self, forKey: .selectedWorktreePath)
        sidebarMode = try container.decodeIfPresent(SidebarMode.self, forKey: .sidebarMode) ?? .repositories
        sessionTabOrder = try container.decodeIfPresent([UUID].self, forKey: .sessionTabOrder) ?? []
        tabs = try container.decodeIfPresent([UUID].self, forKey: .tabs) ?? []
        splitSessionID = try container.decodeIfPresent(UUID.self, forKey: .splitSessionID)
        sidebarVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        wasOpen = try container.decodeIfPresent(Bool.self, forKey: .wasOpen) ?? false
    }
    public func validate() throws {
        try Validation.unique(tabs, field: "tab")
        try Validation.unique(sessionTabOrder, field: "session tab")
        if let selectedWorktreePath { try Validation.absolutePath(selectedWorktreePath) }
    }
}

public struct RetentionSettings: Codable, Equatable, Sendable {
    public var keepFinishedSessions = false
    public var scrollbackLines = 10_000
    public var snapshotBudgetBytes = 256 * 1024 * 1024
    public var completedMessageDays = 90
    public var maxLiveChildren = 4
    /// Submit a short prompt to an idle Codex coordinator when a worker reports or
    /// stops. Codex has no other way to start a turn for a coordinator that ended its own.
    public var wakeIdleCoordinators = true
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case keepFinishedSessions, scrollbackLines, snapshotBudgetBytes, completedMessageDays, maxLiveChildren, wakeIdleCoordinators
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        keepFinishedSessions = try values.decodeIfPresent(Bool.self, forKey: .keepFinishedSessions) ?? false
        scrollbackLines = try values.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 10_000
        snapshotBudgetBytes = try values.decodeIfPresent(Int.self, forKey: .snapshotBudgetBytes) ?? 256 * 1024 * 1024
        completedMessageDays = try values.decodeIfPresent(Int.self, forKey: .completedMessageDays) ?? 90
        maxLiveChildren = try values.decodeIfPresent(Int.self, forKey: .maxLiveChildren) ?? 4
        wakeIdleCoordinators = try values.decodeIfPresent(Bool.self, forKey: .wakeIdleCoordinators) ?? true
    }
    public func validate() throws {
        try Validation.require((100...100_000).contains(scrollbackLines), "Scrollback must be 100–100,000 lines")
        try Validation.require((1_048_576...2_147_483_648).contains(snapshotBudgetBytes), "Snapshot budget must be 1 MiB–2 GiB")
        try Validation.require((1...3650).contains(completedMessageDays), "Message retention must be 1–3,650 days")
        try Validation.require((1...32).contains(maxLiveChildren), "Live child limit must be 1–32")
    }
}
