import Foundation

/// Kimi Code's TypeScript CLI (2.x), not the legacy Python kimi-cli.
public struct KimiProvider: AgentProvider {
    public init() {}
    public var kind: CLIKind { .kimi }
    public var displayName: String { "Kimi Code" }
    public var installURL: URL { URL(string: "https://www.kimi.com/code/docs/en/kimi-code-cli/guides/getting-started")! }
    public var badgeColorName: String { "purple" }
    public func identifies(version: String) -> Bool {
        let parts = version.split(separator: ".")
        return parts.count == 3 && Int(parts[0]).map { $0 >= 2 } == true && Int(parts[1]) != nil && Int(parts[2]) != nil
    }
    public func identifies(version: String, help: String) -> Bool {
        identifies(version: version) && help.contains("Usage: kimi ") && help.contains("--auto") && help.contains("--agent-file")
    }
    public var defaultHomeFolder: String { ".kimi-code" }
    public var configurationEnvironmentKey: String { "KIMI_CODE_HOME" }
    public var skillDiscovery: SkillDiscovery { .sharedAgentsHome }
    public var managedOptions: Set<String> { ["-S", "--session", "-c", "-p", "--prompt", "--output-format", "--skills-dir", "--agent", "--agent-file"] }
    public var managedShortPrefixes: [String] { ["-S", "-c", "-p"] }
    public var valueOptions: Set<String> { ["-m", "--model"] }
    public var flagOptions: Set<String> { ["--auto", "--yolo", "-y", "--plan"] }
    public var modelSuggestions: [String] { [] }
    public var probesModels: Bool { true }
    public var reasoningSuggestions: [String] { [] }
    public func recognize(_ argument: String, field: LaunchOptionField) -> LaunchOptionMatch {
        guard field == .model else { return .none }
        if argument == "-m" || argument == "--model" { return .separate }
        for prefix in ["--model=", "-m="] where argument.hasPrefix(prefix) { return .inline(String(argument.dropFirst(prefix.count))) }
        return .none
    }
    public func canonical(_ field: LaunchOptionField, value: String) -> [String] { field == .model ? ["--model", value] : [] }
    public var autoApprove: AutoApprovePolicy {
        AutoApprovePolicy(flag: "--auto", caption: "Runs without approval prompts", replacedFlags: ["--auto", "--yolo", "-y", "--plan"], replacedValueOptions: [])
    }
    public func composerReadiness(activeLine: String) -> ComposerReadiness { .unrecognized }
    public func composerReadiness(screen: ComposerScreen) -> ComposerReadiness {
        let y = screen.cursorY
        guard y > 0, y + 1 < screen.lines.count else { return .unrecognized }
        let line = screen.lines[y].trimmingCharacters(in: .whitespaces)
        let top = screen.lines[y - 1].trimmingCharacters(in: .whitespaces)
        let bottom = screen.lines[y + 1].trimmingCharacters(in: .whitespaces)
        guard top.hasPrefix("╭─"), top.hasSuffix("╮"), bottom.hasPrefix("╰─"), bottom.hasSuffix("╯"),
              line.hasPrefix("│ >"), line.hasSuffix("│") else { return .unrecognized }
        let text = line.dropFirst(3).dropLast().trimmingCharacters(in: .whitespaces)
        return text.isEmpty && screen.cursorX == 5 ? .ready : .inputPending
    }
    public static func isConversationID(_ id: String) -> Bool {
        for prefix in ["session_", "ses_"] where id.hasPrefix(prefix) {
            if UUID(uuidString: String(id.dropFirst(prefix.count))) != nil { return true }
        }
        return false
    }
    public func validatesConversationID(_ id: String) -> Bool { Self.isConversationID(id) }
    public var identityChangingSources: Set<String> { ["startup", "resume"] }
    public var wakeStrategy: CoordinatorWakeStrategy { .typedPrompt }
}
