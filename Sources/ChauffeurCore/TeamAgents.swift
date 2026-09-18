import Foundation

public enum AgentSelection: String, Codable, CaseIterable, Sendable {
    case allBase, custom
}

/// A global launch definition. Configuration belongs exclusively to a team.
public struct BaseAgentPreset: Record, Equatable {
    public var id = UUID()
    public var name: String
    public var kind: CLIKind
    public var executable: String
    public var arguments: [String] = []
    public var archived = false
    public var revision = 1
    public init(name: String, kind: CLIKind, executable: String) {
        self.name = name; self.kind = kind; self.executable = executable
    }
    public func validate() throws {
        try Validation.name(name)
        try Validation.require(kind.isAgent, "Choose an agent")
        try Validation.require(!executable.isEmpty && !executable.contains("\0"), "Select an executable")
        try Validation.require(revision > 0, "Revision must be positive")
        try LaunchPolicy.validateArguments(arguments, kind: kind)
    }
    public func agent(in team: PresetSet, copy: Bool = false) -> AgentPreset {
        var agent = AgentPreset(setID: team.id, name: name, kind: kind, executable: executable, configurationDirectory: "")
        agent.id = copy ? UUID() : id
        agent.arguments = arguments; agent.archived = archived
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
        return Paths.canonical(URL(fileURLWithPath: home).appendingPathComponent(kind == .claude ? ".claude" : ".codex").path)
    }
    var configurationEnvironment: [String: String] {
        Dictionary(uniqueKeysWithValues: CLIKind.allCases.filter(\.isAgent).map {
            (ShellAgentEnvironment.variableName(for: $0)!, configurationDirectory(for: $0))
        })
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
            if team.agentSelection != nil { resolved.configurationDirectory = team.configurationDirectory(for: agent.kind) }
            return resolved
        }.sorted(by: Self.agentOrder)
    }
    func agents(teamID: UUID, includeArchived: Bool = false) -> [AgentPreset] {
        guard let team = presetSets.first(where: { $0.value.id == teamID })?.value else { return [] }
        return agents(in: team, includeArchived: includeArchived)
    }
    static func agentOrder(_ lhs: AgentPreset, _ rhs: AgentPreset) -> Bool {
        let comparison = lhs.name.compare(rhs.name, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
    }
    func configurationEnvironment(in team: PresetSet) -> [String: String] {
        if team.agentSelection != nil { return team.configurationEnvironment }
        return ShellAgentEnvironment.variables(presets: presets.map(\.value), set: team)
    }
}
