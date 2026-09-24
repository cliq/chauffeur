import Foundation

public enum AgentSelection: String, Codable, CaseIterable, Sendable {
    case allBase, custom
}

/// A global launch definition that inherits team configuration unless overridden.
public struct BaseAgentPreset: Record, Equatable {
    public var id = UUID()
    public var name: String
    public var kind: CLIKind
    public var executable: String
    /// nil inherits the team directory; a value selects a fixed configuration.
    public var configurationDirectoryOverride: String?
    public var arguments: [String] = []
    /// Authoritative editable text when present. Legacy records use `arguments`.
    public var rawArguments: String?
    public var archived = false
    public var revision = 1
    public init(name: String, kind: CLIKind, executable: String) {
        self.name = name; self.kind = kind; self.executable = executable
    }
    public func validate() throws {
        try Validation.name(name)
        if let configurationDirectoryOverride { try Validation.absolutePath(configurationDirectoryOverride) }
        try Validation.require(kind.isAgent, "Choose an agent")
        try Validation.require(!executable.isEmpty && !executable.contains("\0"), "Select an executable")
        try Validation.require(revision > 0, "Revision must be positive")
        if rawArguments == nil { try LaunchPolicy.validateArguments(arguments, kind: kind) }
    }
    public func agent(in team: PresetSet, copy: Bool = false) -> AgentPreset {
        var agent = AgentPreset(setID: team.id, name: name, kind: kind, executable: executable, configurationDirectory: "")
        agent.id = copy ? UUID() : id
        agent.configurationDirectoryOverride = configurationDirectoryOverride
        agent.arguments = arguments; agent.archived = archived
        agent.rawArguments = rawArguments
        agent.sourceBaseID = id; agent.baseRevision = copy ? nil : revision
        return agent
    }
}

public extension PresetSet {
    /// Defaults are explicit at the environment boundary, preventing inherited
    /// provider variables from selecting an unrelated account.
    func configurationDirectory(for kind: CLIKind, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let configured = configurationDirectories?[kind.rawValue] ?? ""
        if !configured.isEmpty { return Paths.canonical(configured) }
        return Paths.canonical(kind.provider?.defaultConfigurationDirectory(home: home) ?? home)
    }
    var configurationEnvironment: [String: String] {
        // Through each provider, so OpenCode's default directory adds no layer.
        AgentProviders.all.reduce(into: [:]) { result, provider in result.merge(provider.environment(configurationDirectory: configurationDirectory(for: provider.kind))) { _, new in new } }
    }
}

public extension StoreSnapshot {
    /// The single availability/configuration resolver used by UI, runtime and API.
    /// nil selection is a legacy record awaiting migration.
    func agents(in team: PresetSet, includeArchived: Bool = false) -> [AgentPreset] {
        guard includeArchived || !team.archived else { return [] }
        let definitions = team.agentSelection == .allBase
            ? baseAgentPresets.map { $0.value.agent(in: team) }
            : presets.map(\.value).filter { $0.setID == team.id }
        return definitions.filter { $0.kind.isAgent && (includeArchived || !$0.archived) }.map { agent in
            var resolved = agent
            if team.agentSelection != nil { resolved.configurationDirectory = agent.configurationDirectoryOverride.map(Paths.canonical) ?? team.configurationDirectory(for: agent.kind) }
            return resolved
        }.sorted(by: Self.agentOrder)
    }
    func agents(teamID: UUID, includeArchived: Bool = false) -> [AgentPreset] {
        guard let team = presetSets.first(where: { $0.value.id == teamID })?.value else { return [] }
        return agents(in: team, includeArchived: includeArchived)
    }
    static func agentOrder(_ lhs: AgentPreset, _ rhs: AgentPreset) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let left = lhs.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let right = rhs.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let comparison = left.compare(right, options: .numeric, locale: locale)
        return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
    }
    func configurationEnvironment(in team: PresetSet) -> [String: String] {
        if team.agentSelection != nil { return team.configurationEnvironment }
        return ShellAgentEnvironment.variables(presets: presets.map(\.value), set: team)
    }
}
