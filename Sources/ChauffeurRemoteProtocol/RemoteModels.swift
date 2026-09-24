import CryptoKit
import Foundation

// MARK: - Sessions

public enum RemoteSessionKind: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
    case opencode
    case shell
    /// An agent this build doesn't know, from a newer Mac.
    case agent

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteSessionKind(rawValue: raw) ?? .agent
    }
}

public enum RemoteSessionState: String, Codable, Sendable, CaseIterable {
    case starting
    case running
    case needsAttention
    case turnFinished
    case exited
    case failed
    case interrupted
    case activityUnknown

    public var isLive: Bool {
        switch self {
        case .starting, .running, .needsAttention, .turnFinished, .activityUnknown:
            return true
        case .exited, .failed, .interrupted:
            return false
        }
    }

    public var label: String {
        switch self {
        case .starting: return "Starting"
        case .running: return "Running"
        case .needsAttention: return "Needs attention"
        case .turnFinished: return "Turn finished"
        case .exited: return "Exited"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .activityUnknown: return "Activity unknown"
        }
    }
}

public enum RemoteAvailability: String, Codable, Sendable {
    case available
    case missing
    case inaccessible
}

// MARK: - Inventory summaries

public struct GroupSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isDefault: Bool

    public init(id: UUID, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

public struct PresetSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: RemoteSessionKind

    public init(id: UUID, name: String, kind: RemoteSessionKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public enum CheckoutKind: String, Codable, Sendable {
    case main
    case worktree
}

public struct CheckoutSummary: Codable, Equatable, Sendable, Identifiable {
    public var kind: CheckoutKind
    public var worktreeID: UUID?
    public var branch: String
    public var path: String
    public var availability: RemoteAvailability
    public var managed: Bool

    public var id: String { path }

    public init(
        kind: CheckoutKind,
        worktreeID: UUID? = nil,
        branch: String,
        path: String,
        availability: RemoteAvailability,
        managed: Bool = false
    ) {
        self.kind = kind
        self.worktreeID = worktreeID
        self.branch = branch
        self.path = path
        self.availability = availability
        self.managed = managed
    }
}

public struct FolderSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var isRepository: Bool
    public var inventoryReady: Bool
    public var availability: RemoteAvailability
    public var checkouts: [CheckoutSummary]

    public init(
        id: UUID,
        name: String,
        path: String,
        isRepository: Bool,
        inventoryReady: Bool = false,
        availability: RemoteAvailability,
        checkouts: [CheckoutSummary] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isRepository = isRepository
        self.inventoryReady = inventoryReady
        self.availability = availability
        self.checkouts = checkouts
    }
}

public struct ProjectSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var archived: Bool
    public var groups: [GroupSummary]
    public var presets: [PresetSummary]
    public var folders: [FolderSummary]

    public init(
        id: UUID,
        name: String,
        archived: Bool = false,
        groups: [GroupSummary] = [],
        presets: [PresetSummary] = [],
        folders: [FolderSummary] = []
    ) {
        self.id = id
        self.name = name
        self.archived = archived
        self.groups = groups
        self.presets = presets
        self.folders = folders
    }
}

public struct SessionSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var folderID: UUID
    public var worktreeID: UUID?
    public var title: String
    public var kind: RemoteSessionKind
    public var state: RemoteSessionState
    public var needsAttention: Bool
    public var branch: String?
    public var checkoutPath: String
    public var attached: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var progress: SessionProgressSummary?

    public init(
        id: UUID,
        projectID: UUID,
        folderID: UUID,
        worktreeID: UUID? = nil,
        title: String,
        kind: RemoteSessionKind,
        state: RemoteSessionState,
        needsAttention: Bool = false,
        branch: String? = nil,
        checkoutPath: String,
        attached: Bool = false,
        createdAt: Date,
        updatedAt: Date,
        progress: SessionProgressSummary? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.folderID = folderID
        self.worktreeID = worktreeID
        self.title = title
        self.kind = kind
        self.state = state
        self.needsAttention = needsAttention
        self.branch = branch
        self.checkoutPath = checkoutPath
        self.attached = attached
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.progress = progress
    }
}

public struct InventorySnapshot: Codable, Equatable, Sendable {
    public var revision: UInt64
    public var hostName: String
    public var projects: [ProjectSummary]
    public var sessions: [SessionSummary]
    public var generatedAt: Date

    public init(
        revision: UInt64,
        hostName: String,
        projects: [ProjectSummary] = [],
        sessions: [SessionSummary] = [],
        generatedAt: Date
    ) {
        self.revision = revision
        self.hostName = hostName
        self.projects = projects
        self.sessions = sessions
        self.generatedAt = generatedAt
    }
}

public extension InventorySnapshot {
    /// The inventory as a client with these hello capabilities can decode it: without `openSessionKinds`, sessions and
    /// presets of a kind it doesn't know are sent as `shell`.
    func compatible(withClientCapabilities capabilities: [String]) -> InventorySnapshot {
        guard !capabilities.contains(RemoteProtocol.openSessionKinds) else { return self }
        func legacy(_ kind: RemoteSessionKind) -> RemoteSessionKind { RemoteProtocol.legacySessionKinds.contains(kind) ? kind : .shell }
        var result = self
        for index in result.sessions.indices { result.sessions[index].kind = legacy(result.sessions[index].kind) }
        for project in result.projects.indices {
            for preset in result.projects[project].presets.indices {
                result.projects[project].presets[preset].kind = legacy(result.projects[project].presets[preset].kind)
            }
        }
        return result
    }
}

// MARK: - Host / pairing

public struct HostInfo: Codable, Equatable, Sendable {
    public var hostID: UUID
    public var hostName: String
    public var runtimeVersion: String
    public var build: String
    public var protocolVersion: Int
    public var capabilities: [String]

    public init(
        hostID: UUID,
        hostName: String,
        runtimeVersion: String,
        build: String,
        protocolVersion: Int,
        capabilities: [String] = []
    ) {
        self.hostID = hostID
        self.hostName = hostName
        self.runtimeVersion = runtimeVersion
        self.build = build
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct PairingResult: Codable, Equatable, Sendable {
    public var remoteAccessKey: Data
    public var deviceID: UUID
    public var deviceToken: String
    public var mainPort: Int
    public var hostID: UUID
    public var hostName: String

    public init(
        remoteAccessKey: Data,
        deviceID: UUID,
        deviceToken: String,
        mainPort: Int,
        hostID: UUID,
        hostName: String
    ) {
        self.remoteAccessKey = remoteAccessKey
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.mainPort = mainPort
        self.hostID = hostID
        self.hostName = hostName
    }
}

// MARK: - Launch / worktree operations

public struct WorktreeCreationSpec: Codable, Equatable, Sendable {
    public var branch: String
    public var baseRef: String

    public init(branch: String, baseRef: String) {
        self.branch = branch
        self.baseRef = baseRef
    }
}

public struct LaunchSpec: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var folderID: UUID
    public var groupID: UUID?
    public var worktreeID: UUID?
    /// nil means launch a plain shell session.
    public var agentPresetID: UUID?
    public var title: String?
    public var task: String?
    public var allowSharedCheckout: Bool

    public init(
        projectID: UUID,
        folderID: UUID,
        groupID: UUID? = nil,
        worktreeID: UUID? = nil,
        agentPresetID: UUID? = nil,
        title: String? = nil,
        task: String? = nil,
        allowSharedCheckout: Bool = false
    ) {
        self.projectID = projectID
        self.folderID = folderID
        self.groupID = groupID
        self.worktreeID = worktreeID
        self.agentPresetID = agentPresetID
        self.title = title
        self.task = task
        self.allowSharedCheckout = allowSharedCheckout
    }
}

public struct LaunchOperationRequest: Codable, Equatable, Sendable {
    public var operationKey: UUID
    public var fingerprint: String
    public var newWorktree: WorktreeCreationSpec?
    public var launch: LaunchSpec

    public init(
        operationKey: UUID,
        fingerprint: String,
        newWorktree: WorktreeCreationSpec? = nil,
        launch: LaunchSpec
    ) {
        self.operationKey = operationKey
        self.fingerprint = fingerprint
        self.newWorktree = newWorktree
        self.launch = launch
    }

    /// Encodes `[newWorktree, launch]` as a sorted-key JSON array and returns its
    /// lowercase hex SHA-256 digest, so identical requests always fingerprint the same way.
    public static func computeFingerprint(newWorktree: WorktreeCreationSpec?, launch: LaunchSpec) -> String {
        let payload = FingerprintPayload(newWorktree: newWorktree, launch: launch)
        let data = try! RemoteJSON.encode(payload) // Encoding these Sendable value types cannot fail.
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct FingerprintPayload: Encodable {
        var newWorktree: WorktreeCreationSpec?
        var launch: LaunchSpec

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(newWorktree)
            try container.encode(launch)
        }
    }
}

public enum OperationPhase: String, Codable, Sendable {
    case creatingWorktree
    case worktreeReady
    case launching
    case completed
    case failed
}

public struct OperationStatus: Codable, Equatable, Sendable {
    public var operationKey: UUID
    public var phase: OperationPhase
    public var worktreeID: UUID?
    public var sessionID: UUID?
    public var error: RemoteError?
    public var updatedAt: Date

    public init(
        operationKey: UUID,
        phase: OperationPhase,
        worktreeID: UUID? = nil,
        sessionID: UUID? = nil,
        error: RemoteError? = nil,
        updatedAt: Date
    ) {
        self.operationKey = operationKey
        self.phase = phase
        self.worktreeID = worktreeID
        self.sessionID = sessionID
        self.error = error
        self.updatedAt = updatedAt
    }
}

public struct WorktreeDestinationPreview: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

// MARK: - Terminal attachment

public struct AttachmentInfo: Codable, Equatable, Sendable {
    public var generation: UInt64
    public var sessionID: UUID
    public var cols: Int
    public var rows: Int

    public init(generation: UInt64, sessionID: UUID, cols: Int, rows: Int) {
        self.generation = generation
        self.sessionID = sessionID
        self.cols = cols
        self.rows = rows
    }
}

public enum AttachmentEndReason: String, Codable, Sendable {
    case controlLost
    case clientDetached
    case sessionEnded
    case slowConsumer
    case transportClosed
    case revoked
}
