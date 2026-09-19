import Foundation

public enum CopyCategory: String, Codable, CaseIterable, Sendable {
    case preferences, instructions, reusable, plugins, connections, hooks, history

    public static func supported(for kind: CLIKind) -> Set<CopyCategory> {
        switch kind {
        case .claude: Set(allCases)
        case .codex: [.preferences, .instructions, .reusable, .plugins, .connections]
        case .shell: []
        }
    }
}

public enum SetupAuthPhase: String, Codable, Sendable, CaseIterable {
    case notChecked, signingIn, verifying, connected, signInRequired, unableToVerify, failed
}

public struct SetupAuthStatus: Codable, Sendable, Equatable {
    public var phase: SetupAuthPhase
    public var email: String?
    public var organization: String?
    public var method: String?
    public var checkedAt: Date?
    public var message: String?

    public init(
        phase: SetupAuthPhase = .notChecked, email: String? = nil,
        organization: String? = nil, method: String? = nil,
        checkedAt: Date? = nil, message: String? = nil
    ) {
        self.phase = phase
        self.email = email
        self.organization = organization
        self.method = method
        self.checkedAt = checkedAt
        self.message = message
    }
}

public struct DiscoveredConfiguration: Codable, Sendable, Equatable {
    public var kind: CLIKind
    public var path: String
    public var displayName: String
    public var isCurrent: Bool
    public var available: Bool

    public init(kind: CLIKind = .codex, path: String = "", displayName: String = "", isCurrent: Bool = false, available: Bool = false) {
        self.kind = kind
        self.path = path
        self.displayName = displayName
        self.isCurrent = isCurrent
        self.available = available
    }
}

public struct SetupInventory: Codable, Sendable, Equatable {
    public var homePath: String
    public var configurations: [DiscoveredConfiguration]
    public var executables: [String: String]
    public var missingAgents: [CLIKind]

    public init(
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path,
        configurations: [DiscoveredConfiguration] = [], executables: [String: String] = [:],
        missingAgents: [CLIKind] = []
    ) {
        self.homePath = homePath
        self.configurations = configurations
        self.executables = executables
        self.missingAgents = missingAgents
    }
}

public struct CopyEntry: Codable, Sendable, Equatable {
    public var sourceRelativePath: String
    public var destinationRelativePath: String
    public var category: CopyCategory
    public var sourceDigest: String
    public var size: Int64

    public init(
        sourceRelativePath: String = "", destinationRelativePath: String = "",
        category: CopyCategory = .preferences, sourceDigest: String = "", size: Int64 = 0
    ) {
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.category = category
        self.sourceDigest = sourceDigest
        self.size = size
    }
}

public struct CopyPreview: Codable, Sendable, Equatable {
    public var id: UUID
    public var pairID: UUID
    public var sourcePath: String?
    public var destinationPath: String
    public var entries: [CopyEntry]
    public var availableProjects: [String]
    public var warnings: [String]
    public var selectionDigest: String

    public init(
        id: UUID = UUID(), pairID: UUID = UUID(), sourcePath: String? = nil,
        destinationPath: String = "", entries: [CopyEntry] = [], warnings: [String] = [],
        selectionDigest: String = "", availableProjects: [String] = []
    ) {
        self.id = id
        self.pairID = pairID
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.entries = entries
        self.availableProjects = availableProjects
        self.warnings = warnings
        self.selectionDigest = selectionDigest
    }
}

public struct CopyReceipt: Codable, Sendable, Equatable {
    public var operationID: UUID
    public var destinationPath: String
    public var files: [String: String]

    public init(operationID: UUID = UUID(), destinationPath: String = "", files: [String: String] = [:]) {
        self.operationID = operationID
        self.destinationPath = destinationPath
        self.files = files
    }
}

public enum SetupOperationPhase: String, Codable, Sendable, CaseIterable {
    case prepared, staged, published, teamSaved, failed
}

public struct SetupOperation: Record, Equatable {
    public var id: UUID
    public var draftID: UUID
    public var pairID: UUID
    public var destinationPath: String
    public var stagingPath: String?
    public var previewID: UUID?
    public var phase: SetupOperationPhase
    public var files: [String: String]
    public var presetIDs: [String: UUID]
    public var message: String?

    public init(
        id: UUID = UUID(), draftID: UUID = UUID(), pairID: UUID = UUID(),
        destinationPath: String = "", stagingPath: String? = nil, previewID: UUID? = nil,
        phase: SetupOperationPhase = .prepared, files: [String: String] = [:],
        presetIDs: [String: UUID] = [:], message: String? = nil
    ) {
        self.id = id
        self.draftID = draftID
        self.pairID = pairID
        self.destinationPath = destinationPath
        self.stagingPath = stagingPath
        self.previewID = previewID
        self.phase = phase
        self.files = files
        self.presetIDs = presetIDs
        self.message = message
    }

    public func validate() throws {
        try Validation.absolutePath(destinationPath)
        if let stagingPath { try Validation.absolutePath(stagingPath) }
        for (path, digest) in files {
            try Validation.require(!path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "Operation file path must be relative")
            try Validation.require(!digest.isEmpty && !digest.contains("\0"), "Operation digest is invalid")
        }
        for key in presetIDs.keys { try Validation.require(UUID(uuidString: key) != nil, "Operation base preset ID is invalid") }
        if let message { try Validation.require(message.count <= 2_000 && !message.contains("\0"), "Operation summary is invalid") }
    }
}
