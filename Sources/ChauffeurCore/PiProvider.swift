import Foundation

public struct PiProvider: AgentProvider {
    public init() {}
    public var kind: CLIKind { .pi }
    public var displayName: String { "Pi" }
    public var installURL: URL { URL(string: "https://pi.dev")! }
    public var badgeColorName: String { "pink" }
    public func identifies(version: String) -> Bool {
        let parts = version.split(separator: ".")
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else { return false }
        // agent_before_settle, required for completion and inbox continuation,
        // was introduced in Pi 0.87.0 and is not discoverable through --help.
        return major > 0 || minor >= 87
    }
    public func identifies(version: String, help: String) -> Bool {
        identifies(version: version) && help.contains("pi - AI coding assistant")
            && ["--extension", "--session", "--session-id", "--thinking", "--approve"].allSatisfy(help.contains)
    }
    public var defaultHomeFolder: String { ".pi/agent" }
    public var configurationEnvironmentKey: String { "PI_CODING_AGENT_DIR" }
    public var skillDiscovery: SkillDiscovery { .configurationDirectory }
    public var managedOptions: Set<String> {
        ["-c", "-r", "-p", "--session", "--session-dir", "--fork", "--mode", "--print", "--no-session",
         "--extension", "-e", "--no-extensions", "-ne", "--skill", "--no-skills", "-ns", "--export", "--list-models",
         "--tools", "-t", "--exclude-tools", "-xt", "--no-tools", "-nt", "--api-key"]
    }
    public var managedShortPrefixes: [String] { ["-c", "-r", "-p", "-e", "-t"] }
    public var valueOptions: Set<String> { ["--provider", "--model", "--models", "--thinking", "--system-prompt", "--append-system-prompt", "--name", "-n", "--tui-mode"] }
    public var flagOptions: Set<String> { ["--approve", "-a", "--no-approve", "-na", "--verbose", "--offline", "--no-builtin-tools", "-nbt"] }
    public var modelSuggestions: [String] { [] }
    public var probesModels: Bool { true }
    public var reasoningSuggestions: [String] { ["off", "minimal", "low", "medium", "high", "xhigh", "max"] }
    public func recognize(_ argument: String, field: LaunchOptionField) -> LaunchOptionMatch {
        guard field != .autoApprove else { return .none }
        return argument == (field == .model ? "--model" : "--thinking") ? .separate : .none
    }
    public func canonical(_ field: LaunchOptionField, value: String) -> [String] {
        field == .autoApprove ? [] : [field == .model ? "--model" : "--thinking", value]
    }
    public var autoApprove: AutoApprovePolicy {
        AutoApprovePolicy(flag: "--approve", caption: "Trusts project files; tools already run without approval prompts", alternateFlags: ["-a"], replacedFlags: ["--approve", "-a", "--no-approve", "-na"], replacedValueOptions: [])
    }
    public func composerReadiness(activeLine: String) -> ComposerReadiness { .unrecognized }
    public func composerReadiness(screen: ComposerScreen) -> ComposerReadiness {
        let y = screen.cursorY, lines = screen.lines
        guard y > 0, lines.indices.contains(y + 3) else { return .unrecognized }
        let top = lines[y - 1].trimmingCharacters(in: .whitespaces)
        let bottom = lines[y + 1].trimmingCharacters(in: .whitespaces)
        // Only Pi's standard single-line editor is recognized. Working status,
        // scroll markers, completion lists and custom editors fail closed.
        guard top.count >= 10, top.allSatisfy({ $0 == "─" }), bottom == top,
              lines[y + 2].hasPrefix("/") || lines[y + 2].hasPrefix("~"),
              lines[y + 3].contains("%/") else { return .unrecognized }
        return lines[y].trimmingCharacters(in: .whitespaces).isEmpty && screen.cursorX == 0 ? .ready : .inputPending
    }
    public var preassignsConversationID: Bool { true }
    public var identityChangingSources: Set<String> { ["startup", "new", "resume", "fork"] }
    public var wakeStrategy: CoordinatorWakeStrategy { .plugin }
}
