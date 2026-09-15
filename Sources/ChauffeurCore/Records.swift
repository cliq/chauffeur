import Foundation

public protocol Record: Codable, Identifiable, Sendable where ID == UUID {
    var id: UUID { get }
    func validate() throws
}

public enum CLIKind: String, Codable, CaseIterable, Sendable { case codex, claude }
public enum Availability: String, Codable, Sendable { case available, missing, inaccessible }
public enum IntegrationState: String, Codable, Sendable { case unverified, supported, unavailable }

public struct PresetSet: Record, Equatable {
    public var id = UUID()
    public var name: String
    public var defaultPresetID: UUID?
    public var revision = 1
    public var archived = false
    public init(name: String) { self.name = name }
    public func validate() throws { try Validation.name(name); try Validation.require(revision > 0, "Revision must be positive") }
}

public struct AgentPreset: Record, Equatable {
    public var id = UUID()
    public var setID: UUID
    public var name: String
    public var kind: CLIKind
    public var executable: String
    public var configurationDirectory: String
    public var arguments: [String] = []
    public var integration: IntegrationState = .unverified
    public var archived = false
    public init(setID: UUID, name: String, kind: CLIKind, executable: String, configurationDirectory: String) {
        self.setID = setID; self.name = name; self.kind = kind
        self.executable = executable; self.configurationDirectory = configurationDirectory
    }
    public func validate() throws {
        try Validation.name(name)
        try Validation.require(!executable.isEmpty && !executable.contains("\0"), "Select an executable")
        try Validation.absolutePath(configurationDirectory)
        try LaunchPolicy.validateArguments(arguments, kind: kind)
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

public struct LaunchSnapshot: Codable, Equatable, Sendable {
    public var preset: AgentPreset
    public var presetSetName: String
    public var presetSetRevision: Int
    public var executablePath: String
    public var executableVersion: String
    public var configurationPath: String
    public var workingDirectory: String
    public var additionalPaths: [String]
    public var gitWorktreeIdentities: [UUID]?
    public var launchedAt = Date()
    public init(preset: AgentPreset, set: PresetSet, executablePath: String, executableVersion: String, workingDirectory: String, additionalPaths: [String]) {
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
    public var parentID: UUID?
    public var delegationID: UUID?
    public var initialTask: String?
    public var launchRequestFingerprint: String?
    public var error: String?
    public var failureCode: String?
    public var exitStatus: Int32?
    public var unread = false
    public var pendingMessages = 0
    public var createdAt = Date()
    public var updatedAt = Date()
    public var needsAttention: Bool { pendingMessages > 0 || state == .needsAttention || state == .failed || (state == .turnFinished && unread) }
    public init(projectID: UUID, groupID: UUID, title: String, launch: LaunchSnapshot, folderID: UUID) {
        self.projectID = projectID; self.groupID = groupID; self.title = title; self.launch = launch; self.folderID = folderID
    }
    public func validate() throws {
        try Validation.name(title); try Validation.absolutePath(launch.configurationPath)
        try Validation.absolutePath(launch.workingDirectory)
        if let nativeConversationID { try Validation.require(UUID(uuidString: nativeConversationID) != nil, "Native conversation ID must be a UUID") }
    }
}

public struct Worktree: Record, Equatable {
    public var id = UUID()
    public var projectID: UUID
    public var folderID: UUID
    public var repositoryID: UUID
    public var path: String
    public var repositoryPath: String
    public var branch: String
    public var baseCommit: String
    public var managed: Bool
    public var creationRequestFingerprint: String?
    public var gitIdentity: UUID?
    public var availability: Availability = .available
    public var registered = true
    public init(projectID: UUID, folderID: UUID, repositoryID: UUID, path: String, repositoryPath: String, branch: String, baseCommit: String, managed: Bool) {
        self.projectID = projectID; self.folderID = folderID; self.repositoryID = repositoryID
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
    public var tabs: [UUID] = []
    public var splitSessionID: UUID?
    public var sidebarVisible = true
    public var wasOpen = false
    public init(projectID: UUID) { id = projectID }
    public func validate() throws { try Validation.unique(tabs, field: "tab") }
}

public struct RetentionSettings: Codable, Equatable, Sendable {
    public var scrollbackLines = 10_000
    public var snapshotBudgetBytes = 256 * 1024 * 1024
    public var completedMessageDays = 90
    public var maxLiveChildren = 4
    public init() {}
    public func validate() throws {
        try Validation.require((100...100_000).contains(scrollbackLines), "Scrollback must be 100–100,000 lines")
        try Validation.require((1_048_576...2_147_483_648).contains(snapshotBudgetBytes), "Snapshot budget must be 1 MiB–2 GiB")
        try Validation.require((1...3650).contains(completedMessageDays), "Message retention must be 1–3,650 days")
        try Validation.require((1...32).contains(maxLiveChildren), "Live child limit must be 1–32")
    }
}
