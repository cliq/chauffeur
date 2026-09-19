import Foundation

public enum SetupStep: String, Codable, Sendable, CaseIterable {
    case agents, teams, configurations, copy, login, summary
}

public enum AccountCount: String, Codable, Sendable, CaseIterable {
    case single, multiple, unsure
}

public enum ConfigurationChoice: String, Codable, Sendable, CaseIterable {
    case current, existing, create
}

public struct SetupAgentPair: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CLIKind
    public var executable: String
    public var choice: ConfigurationChoice
    public var sourcePath: String?
    public var destinationPath: String
    public var categories: Set<CopyCategory>
    public var projectPaths: Set<String>
    public var previewID: UUID?
    public var operationID: UUID?
    public var auth: SetupAuthStatus

    public init(
        id: UUID = UUID(), kind: CLIKind = .codex, executable: String = "",
        choice: ConfigurationChoice = .current, sourcePath: String? = nil,
        destinationPath: String = "", categories: Set<CopyCategory> = [.preferences, .instructions, .reusable],
        projectPaths: Set<String> = [], previewID: UUID? = nil,
        operationID: UUID? = nil, auth: SetupAuthStatus = SetupAuthStatus()
    ) {
        self.id = id
        self.kind = kind
        self.executable = executable
        self.choice = choice
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.categories = categories
        self.projectPaths = projectPaths
        self.previewID = previewID
        self.operationID = operationID
        self.auth = auth
    }
}

public struct SetupTeam: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var agents: [SetupAgentPair]
    public var savedVersion: String?
    /// Expected FileStore digest persisted before a team/preset write, for crash recovery.
    public var pendingVersion: String?

    public init(id: UUID = UUID(), name: String = "", agents: [SetupAgentPair] = [], savedVersion: String? = nil, pendingVersion: String? = nil) {
        self.id = id
        self.name = name
        self.agents = agents
        self.savedVersion = savedVersion
        self.pendingVersion = pendingVersion
    }
}

public struct SetupDraft: Record, Equatable {
    public static let currentSchemaVersion = 1

    public var id: UUID
    public var schemaVersion: Int
    public var step: SetupStep
    public var accountCounts: [String: AccountCount]
    public var executables: [String: String]
    public var teams: [SetupTeam]
    public var defaultTeamID: UUID?
    public var dismissed: Bool
    public var completed: Bool

    public init(
        id: UUID = UUID(), schemaVersion: Int = SetupDraft.currentSchemaVersion,
        step: SetupStep = .agents, accountCounts: [String: AccountCount] = [:],
        executables: [String: String] = [:], teams: [SetupTeam] = [], defaultTeamID: UUID? = nil,
        dismissed: Bool = false, completed: Bool = false
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.step = step
        self.accountCounts = accountCounts
        self.executables = executables
        self.teams = teams
        self.defaultTeamID = defaultTeamID
        self.dismissed = dismissed
        self.completed = completed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        step = try values.decode(SetupStep.self, forKey: .step)
        accountCounts = try values.decode([String: AccountCount].self, forKey: .accountCounts)
        executables = try values.decodeIfPresent([String: String].self, forKey: .executables) ?? [:]
        teams = try values.decode([SetupTeam].self, forKey: .teams)
        defaultTeamID = try values.decodeIfPresent(UUID.self, forKey: .defaultTeamID)
        dismissed = try values.decode(Bool.self, forKey: .dismissed)
        completed = try values.decode(Bool.self, forKey: .completed)
        try validate()
    }

    public func validate() throws {
        try Validation.require(schemaVersion > 0 && schemaVersion <= Self.currentSchemaVersion, "Setup was created by a newer version of Chauffeur")
        try Validation.unique(teams.map(\.id), field: "setup team ID")
        let pairs = teams.flatMap(\.agents)
        try Validation.unique(pairs.map(\.id), field: "setup agent pair ID")
        if let defaultTeamID {
            try Validation.require(teams.contains { $0.id == defaultTeamID }, "Default setup team is missing")
        }
        for team in teams {
            try Validation.require(team.name.count <= 240 && !team.name.contains("\0"), "Setup team name is invalid")
            try Validation.unique(team.agents.map(\.kind), field: "team agent")
            for pair in team.agents {
                try Validation.require(pair.kind.isAgent, "Choose an agent")
                try Validation.require(!pair.executable.contains("\0"), "Select a valid executable")
                if let sourcePath = pair.sourcePath {
                    try Validation.require(sourcePath.count <= 4_096 && !sourcePath.contains("\0"), "Setup source path is invalid")
                }
                try Validation.require(pair.destinationPath.count <= 4_096 && !pair.destinationPath.contains("\0"), "Setup destination path is invalid")
                for path in pair.projectPaths { try Validation.absolutePath(path) }
                if let message = pair.auth.message {
                    try Validation.require(message.count <= 2_000 && !message.contains("\0"), "Authentication summary is invalid")
                }
            }
        }
        for key in accountCounts.keys {
            try Validation.require(CLIKind(rawValue: key)?.isAgent == true, "Unknown account-count agent")
        }
        for (key, executable) in executables {
            try Validation.require(CLIKind(rawValue: key)?.isAgent == true, "Unknown setup executable agent")
            try Validation.require(executable.count <= 4_096 && !executable.contains("\0"), "Setup executable is invalid")
        }
    }
}
