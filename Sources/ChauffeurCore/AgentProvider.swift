import Foundation

/// How an idle coordinator learns that its workers reported.
public enum CoordinatorWakeStrategy: Sendable, Equatable {
    /// The coordinator runs Chauffeur's waiter command in the background itself.
    case backgroundWaiter
    /// The runtime types a short prompt into the idle coordinator's composer.
    case typedPrompt
    /// Chauffeur's launch plugin runs the waiter and continues the turn itself.
    case plugin
}

/// Where a provider discovers user skills.
public enum SkillDiscovery: Sendable, Equatable {
    /// `<configuration directory>/skills`, per team.
    case configurationDirectory
    /// `~/.agents/skills`, shared across profiles.
    case sharedAgentsHome
}

public enum ComposerReadiness: Equatable, Sendable { case ready, inputPending, unrecognized }

/// The visible pane and cursor, for composers that can only be read in context.
public struct ComposerScreen: Equatable, Sendable {
    public var lines: [String]
    /// Cell column and row of the cursor.
    public var cursorX: Int
    public var cursorY: Int
    public init(lines: [String], cursorX: Int, cursorY: Int) { self.lines = lines; self.cursorX = cursorX; self.cursorY = cursorY }
}

/// How one argument relates to a launch option.
public enum LaunchOptionMatch: Equatable, Sendable { case none, separate, inline(String) }

/// The flag that puts a session in auto-approve mode and what it supersedes.
public struct AutoApprovePolicy: Equatable, Sendable {
    public var flag: String
    /// What auto-approve does for this provider, shown next to the checkbox.
    public var caption: String
    /// Other flags that turn auto-approve on, e.g. Codex `--yolo`.
    public var alternateFlags: Set<String>
    /// Option values that turn auto-approve on, e.g. Claude `--permission-mode bypassPermissions`.
    public var enablingValues: [String: String]
    /// Flags removed when `flag` is enforced.
    public var replacedFlags: Set<String>
    /// Options whose value is removed with them when `flag` is enforced.
    public var replacedValueOptions: Set<String>
    public init(flag: String, caption: String, alternateFlags: Set<String> = [], enablingValues: [String: String] = [:], replacedFlags: Set<String>, replacedValueOptions: Set<String>) {
        self.flag = flag; self.caption = caption; self.alternateFlags = alternateFlags; self.enablingValues = enablingValues
        self.replacedFlags = replacedFlags; self.replacedValueOptions = replacedValueOptions
    }
}

/// Pure, per-provider rules for a first-party agent CLI. `CLIKind` stays the
/// persisted identifier; everything that differs per agent lives here.
public protocol AgentProvider: Sendable {
    var kind: CLIKind { get }
    var displayName: String { get }
    var installURL: URL { get }
    var badgeColorName: String { get }
    /// Recognizes the provider from `--version` output without pinning a release.
    func identifies(version: String) -> Bool
    /// Recognizes the provider from `--version` and `--help` output together.
    func identifies(version: String, help: String) -> Bool
    /// Why coordination is limited for a recognized build, if it is.
    var coordinationLimitation: String? { get }

    /// The profile folder under the user's home, e.g. `.claude`.
    var defaultHomeFolder: String { get }
    /// The variable that selects a profile folder, e.g. `CLAUDE_CONFIG_DIR`.
    var configurationEnvironmentKey: String { get }
    /// Variables that select `configurationDirectory` for a launch.
    func environment(configurationDirectory: String) -> [String: String]
    var skillDiscovery: SkillDiscovery { get }

    /// Chauffeur-managed options, beyond `LaunchPolicy.commonManagedOptions`.
    var managedOptions: Set<String> { get }
    /// Short options whose attached values (`-C/tmp`) would bypass `managedOptions`.
    var managedShortPrefixes: [String] { get }
    var valueOptions: Set<String> { get }
    var flagOptions: Set<String> { get }
    /// A managed option the user may still set for this `value`.
    func permitsManaged(_ key: String, value: String?) -> Bool
    func validateAdditionalDirectories(arguments: [String]) throws

    var modelSuggestions: [String] { get }
    /// Model suggestions come from the capability probe (`ModelSuggestionCache`).
    var probesModels: Bool { get }
    var reasoningSuggestions: [String] { get }
    var supportsReasoning: Bool { get }
    /// Model and reasoning only; `autoApprove` is read from `autoApprove`.
    func recognize(_ argument: String, field: LaunchOptionField) -> LaunchOptionMatch
    /// The option's value when `next` follows a `.separate` match, or nil when
    /// that pair belongs to another setting.
    func separateValue(_ next: String, field: LaunchOptionField) -> String?
    func canonical(_ field: LaunchOptionField, value: String) -> [String]
    var autoApprove: AutoApprovePolicy { get }

    /// Whether the cursor line (trimmed) is an empty composer, a draft or a dialog.
    func composerReadiness(activeLine: String) -> ComposerReadiness
    /// The same, for rules that need the lines around the cursor.
    func composerReadiness(screen: ComposerScreen) -> ComposerReadiness

    /// Chauffeur names the native conversation before launch.
    var preassignsConversationID: Bool { get }
    func validatesConversationID(_ id: String) -> Bool
    /// `SessionStart` sources after which the provider continues in another conversation.
    var identityChangingSources: Set<String> { get }
    func adoptsFirstConversation(hooksTrusted: Bool, hookEvent: String?) -> Bool
    var wakeStrategy: CoordinatorWakeStrategy { get }
    /// The longest `chauffeur_inbox` wait the provider's MCP transport survives.
    var maxInboxWaitSeconds: Int? { get }
}

public extension AgentProvider {
    var coordinationLimitation: String? { nil }
    func identifies(version: String, help: String) -> Bool { identifies(version: version) }
    var probesModels: Bool { false }
    func composerReadiness(screen: ComposerScreen) -> ComposerReadiness {
        guard screen.lines.indices.contains(screen.cursorY) else { return .unrecognized }
        return composerReadiness(activeLine: screen.lines[screen.cursorY].trimmingCharacters(in: .whitespaces))
    }
    var maxInboxWaitSeconds: Int? { nil }
    func environment(configurationDirectory: String) -> [String: String] { [configurationEnvironmentKey: configurationDirectory] }
    func defaultConfigurationDirectory(home: String) -> String { URL(fileURLWithPath: home).appendingPathComponent(defaultHomeFolder).path }
    func permitsManaged(_ key: String, value: String?) -> Bool { false }
    func validateAdditionalDirectories(arguments: [String]) throws {}
    var supportsReasoning: Bool { !reasoningSuggestions.isEmpty }
    func separateValue(_ next: String, field: LaunchOptionField) -> String? { next }
    var preassignsConversationID: Bool { false }
    func validatesConversationID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
    func adoptsFirstConversation(hooksTrusted: Bool, hookEvent: String?) -> Bool { true }
}

public enum AgentProviders {
    /// In `CLIKind.allCases` order.
    public static let all: [any AgentProvider] = [CodexProvider(), ClaudeProvider(), OpenCodeProvider()]
}

public extension CLIKind {
    /// nil for `.shell`, which has no native agent integration.
    var provider: (any AgentProvider)? { AgentProviders.all.first { $0.kind == self } }
    /// The profile folder under the user's home, e.g. `.claude`.
    var defaultHomeFolder: String { provider?.defaultHomeFolder ?? ".\(rawValue)" }
}

public struct ClaudeProvider: AgentProvider {
    public init() {}
    public var kind: CLIKind { .claude }
    public var displayName: String { "Claude Code" }
    public var installURL: URL { URL(string: "https://code.claude.com/docs/en/setup")! }
    public var badgeColorName: String { "orange" }
    public func identifies(version: String) -> Bool { version.hasSuffix("(Claude Code)") }
    public var defaultHomeFolder: String { ".claude" }
    public var configurationEnvironmentKey: String { "CLAUDE_CONFIG_DIR" }
    public var skillDiscovery: SkillDiscovery { .configurationDirectory }

    public var managedOptions: Set<String> {
        ["-c", "-r", "-w", "--mcp-config", "--strict-mcp-config", "--settings", "--setting-sources", "--safe-mode", "--no-session-persistence", "--print", "-p", "--output-format", "--input-format", "--plugin-dir", "--plugin-url", "--environment", "--tmux"]
    }
    public var managedShortPrefixes: [String] { ["-r", "-w"] }
    public var valueOptions: Set<String> {
        ["--model", "--effort", "--permission-mode", "--agent", "--agents", "--append-system-prompt", "--system-prompt", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--tools", "--name", "-n", "--fallback-model"]
    }
    public var flagOptions: Set<String> { ["--verbose", "--chrome", "--no-chrome", "--ide", "--disable-slash-commands", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"] }

    public var modelSuggestions: [String] { ["opus", "sonnet", "haiku"] }
    public var reasoningSuggestions: [String] { ["low", "medium", "high", "xhigh", "max"] }
    public func recognize(_ argument: String, field: LaunchOptionField) -> LaunchOptionMatch {
        guard field != .autoApprove else { return .none }
        let option = field == .model ? "--model" : "--effort"
        if argument == option { return .separate }
        if argument.hasPrefix(option + "=") { return .inline(String(argument.dropFirst(option.count + 1))) }
        return .none
    }
    public func canonical(_ field: LaunchOptionField, value: String) -> [String] { [field == .model ? "--model" : "--effort", value] }
    public var autoApprove: AutoApprovePolicy {
        // `--allow-dangerously-skip-permissions` only offers the mode, so it does not count as on.
        AutoApprovePolicy(flag: "--dangerously-skip-permissions", caption: "Skips permission prompts", enablingValues: ["--permission-mode": "bypassPermissions"], replacedFlags: ["--allow-dangerously-skip-permissions", "--dangerously-skip-permissions"], replacedValueOptions: ["--permission-mode"])
    }

    public func composerReadiness(activeLine line: String) -> ComposerReadiness {
        guard line.first == "❯" else { return .unrecognized }
        return line.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty ? .ready : .inputPending
    }

    public var preassignsConversationID: Bool { true }
    public var identityChangingSources: Set<String> { ["clear", "resume"] }
    public var wakeStrategy: CoordinatorWakeStrategy { .backgroundWaiter }
}

public struct CodexProvider: AgentProvider {
    private static let reasoningKey = "model_reasoning_effort="
    public init() {}
    public var kind: CLIKind { .codex }
    public var displayName: String { "Codex" }
    public var installURL: URL { URL(string: "https://developers.openai.com/codex/cli")! }
    public var badgeColorName: String { "blue" }
    public func identifies(version: String) -> Bool { version.hasPrefix("codex-cli ") }
    public var coordinationLimitation: String? { "Turn completion via notify; approval/input detection is unavailable" }
    public var defaultHomeFolder: String { ".codex" }
    public var configurationEnvironmentKey: String { "CODEX_HOME" }
    public var skillDiscovery: SkillDiscovery { .sharedAgentsHome }

    public var managedOptions: Set<String> { ["-C", "--cd", "-c", "--config", "--last", "--all"] }
    public var managedShortPrefixes: [String] { ["-C", "-c"] }
    public var valueOptions: Set<String> {
        ["-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "--enable", "--disable", "--local-provider", "-i", "--image", "-c", "--config"]
    }
    public var flagOptions: Set<String> { ["--search", "--no-alt-screen", "--oss", "--strict-config", "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox", "--yolo"] }
    /// Only the reasoning config is the user's; every other `-c` is Chauffeur's.
    public func permitsManaged(_ key: String, value: String?) -> Bool {
        (key == "-c" || key == "--config") && value?.hasPrefix(Self.reasoningKey) == true
    }
    public func validateAdditionalDirectories(arguments: [String]) throws {
        let readOnly = arguments.enumerated().contains { index, argument in
            argument == "--sandbox=read-only" || argument == "-s=read-only"
                || ((argument == "--sandbox" || argument == "-s") && arguments.dropFirst(index + 1).first == "read-only")
        }
        guard !readOnly else {
            throw ChauffeurError("unsupported_directories", "Codex's read-only sandbox cannot add writable folders. Remove the additional folders or select workspace-write in the agent preset's launch arguments")
        }
    }

    public var modelSuggestions: [String] { ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"] }
    public var reasoningSuggestions: [String] { ["low", "medium", "high", "xhigh"] }
    private static func reasoning(_ config: String) -> String { String(config.dropFirst(reasoningKey.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    public func recognize(_ argument: String, field: LaunchOptionField) -> LaunchOptionMatch {
        switch field {
        case .model:
            if argument == "-m" || argument == "--model" { return .separate }
            if argument.hasPrefix("--model=") { return .inline(String(argument.dropFirst("--model=".count))) }
            if argument.hasPrefix("-m=") { return .inline(String(argument.dropFirst(3))) }
        case .reasoning:
            if argument == "-c" || argument == "--config" { return .separate }
            for prefix in ["-c=", "--config="] where argument.hasPrefix(prefix) {
                let config = String(argument.dropFirst(prefix.count))
                if config.hasPrefix(Self.reasoningKey) { return .inline(Self.reasoning(config)) }
            }
        case .autoApprove: break
        }
        return .none
    }
    /// `-c` pairs with other keys are unrelated managed config and stay verbatim.
    public func separateValue(_ next: String, field: LaunchOptionField) -> String? {
        guard field == .reasoning else { return next }
        return next.hasPrefix(Self.reasoningKey) ? Self.reasoning(next) : nil
    }
    public func canonical(_ field: LaunchOptionField, value: String) -> [String] {
        field == .model ? ["--model", value] : ["-c", Self.reasoningKey + value]
    }
    public var autoApprove: AutoApprovePolicy {
        AutoApprovePolicy(flag: "--dangerously-bypass-approvals-and-sandbox", caption: "Skips approvals and the sandbox", alternateFlags: ["--yolo"], replacedFlags: ["--approve-for-me", "--dangerously-bypass-approvals-and-sandbox", "--yolo"], replacedValueOptions: ["-s", "--sandbox", "-a", "--ask-for-approval"])
    }

    public func composerReadiness(activeLine line: String) -> ComposerReadiness {
        if line == "› Ask Codex to do anything" { return .ready }
        if line == "›" || line.hasPrefix("› ") { return .inputPending }
        return .unrecognized
    }

    // Codex `/new` reports `startup` too (verified in Codex 0.156.1).
    public var identityChangingSources: Set<String> { ["startup", "clear", "resume", "fork"] }
    /// With trusted hooks, only a hook names the first conversation: Codex's title
    /// generator sends `notify` from another thread.
    public func adoptsFirstConversation(hooksTrusted: Bool, hookEvent: String?) -> Bool { !(hooksTrusted && hookEvent == nil) }
    public var wakeStrategy: CoordinatorWakeStrategy { .typedPrompt }
}

public struct OpenCodeProvider: AgentProvider {
    public init() {}
    public var kind: CLIKind { .opencode }
    public var displayName: String { "OpenCode" }
    public var installURL: URL { URL(string: "https://opencode.ai")! }
    public var badgeColorName: String { "teal" }
    /// `--version` is a bare semver, so the help's own subcommands confirm it.
    public func identifies(version: String) -> Bool {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
    public func identifies(version: String, help: String) -> Bool {
        identifies(version: version) && help.contains("opencode serve") && help.contains("opencode acp")
    }
    public var defaultHomeFolder: String { ".config/opencode" }
    public var configurationEnvironmentKey: String { "OPENCODE_CONFIG_DIR" }
    /// `OPENCODE_CONFIG_DIR` adds a layer over `~/.config/opencode`; naming the
    /// global directory again would load its plugins twice.
    public func environment(configurationDirectory: String) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return Paths.canonical(configurationDirectory) == Paths.canonical(defaultConfigurationDirectory(home: home)) ? [:] : [configurationEnvironmentKey: configurationDirectory]
    }
    public var skillDiscovery: SkillDiscovery { .sharedAgentsHome }

    /// `--pure` disables the status plugin; `--mini` is a different UI.
    public var managedOptions: Set<String> {
        ["-c", "--continue", "-s", "--session", "--fork", "--prompt", "--port", "--hostname", "--mdns", "--mdns-domain", "--cors", "--pure", "--mini", "--no-replay", "--replay-limit"]
    }
    public var managedShortPrefixes: [String] { ["-c", "-s"] }
    public var valueOptions: Set<String> { ["-m", "--model", "--agent", "--log-level"] }
    public var flagOptions: Set<String> { ["--auto", "--print-logs"] }

    public var modelSuggestions: [String] { [] }
    public var probesModels: Bool { true }
    public var reasoningSuggestions: [String] { [] }
    public func recognize(_ argument: String, field: LaunchOptionField) -> LaunchOptionMatch {
        guard field == .model else { return .none }
        if argument == "-m" || argument == "--model" { return .separate }
        if argument.hasPrefix("--model=") { return .inline(String(argument.dropFirst("--model=".count))) }
        if argument.hasPrefix("-m=") { return .inline(String(argument.dropFirst(3))) }
        return .none
    }
    public func canonical(_ field: LaunchOptionField, value: String) -> [String] { field == .model ? ["--model", value] : [] }
    public var autoApprove: AutoApprovePolicy {
        AutoApprovePolicy(flag: "--auto", caption: "Approves anything not explicitly denied", replacedFlags: ["--auto"], replacedValueOptions: [])
    }

    /// Only the active line is known here, which cannot prove an empty prompt.
    public func composerReadiness(activeLine line: String) -> ComposerReadiness {
        guard line.first == "┃" else { return .unrecognized }
        return line.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty ? .unrecognized : .inputPending
    }
    /// The prompt is a `┃` box above an agent/model line and a `╹▀` edge, and it
    /// looks the same while busy. The footer's `esc interrupt` tells busy apart, and
    /// dialogs move the cursor out of the box (V9).
    public func composerReadiness(screen: ComposerScreen) -> ComposerReadiness {
        let lines = screen.lines, y = screen.cursorY
        func bar(_ index: Int) -> (column: Int, rest: String)? {
            guard lines.indices.contains(index) else { return nil }
            let scalars = Array(lines[index].unicodeScalars)
            guard let column = scalars.firstIndex(where: { $0 != " " }), scalars[column] == "┃" else { return nil }
            return (column, String(String.UnicodeScalarView(scalars[(column + 1)...])).trimmingCharacters(in: .whitespaces))
        }
        guard let cursor = bar(y) else { return .unrecognized }
        let above = bar(y - 1)
        let placeholder = cursor.rest.hasPrefix("Ask anything")
        if (!cursor.rest.isEmpty && !placeholder) || (above.map { !$0.rest.isEmpty && $0.column == cursor.column } ?? false) { return .inputPending }
        guard screen.cursorX == cursor.column + 3, let above, above.column == cursor.column,
              let below = bar(y + 1), below.column == cursor.column, below.rest.isEmpty,
              lines.indices.contains(y + 3) else { return .unrecognized }
        let status = lines[y + 2].trimmingCharacters(in: .whitespaces)
        guard !status.isEmpty, status != "┃", !status.hasPrefix("╹"), lines[y + 3].trimmingCharacters(in: .whitespaces).hasPrefix("╹▀") else { return .unrecognized }
        guard !lines[(y + 4)...].contains(where: { $0.contains("esc interrupt") }) else { return .unrecognized }
        return .ready
    }

    /// `ses_` followed by 26 alphanumerics.
    public static func isConversationID(_ id: String) -> Bool {
        id.hasPrefix("ses_") && id.count == 30 && id.dropFirst(4).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    public func validatesConversationID(_ id: String) -> Bool { Self.isConversationID(id) }
    /// The plugin reports only the first root session, so nothing moves the session later.
    public var identityChangingSources: Set<String> { [] }
    public var wakeStrategy: CoordinatorWakeStrategy { .plugin }
    /// Plain JSON MCP replies fail after about 300 s (V9).
    public var maxInboxWaitSeconds: Int? { 240 }
}
