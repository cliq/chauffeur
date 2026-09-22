import Foundation

public enum LaunchOptionField: Equatable, Sendable {
    case model, reasoning
}

public enum WorkerExecutionPolicy: String, Codable, Sendable {
    case standard
    case delegatedYOLO
}

public struct LaunchArgumentInspection: Equatable, Sendable {
    public var arguments: [String]?
    public var model: String?
    public var reasoning: String?
    public var warnings: [String]

    public init(arguments: [String]?, model: String?, reasoning: String?, warnings: [String]) {
        self.arguments = arguments
        self.model = model
        self.reasoning = reasoning
        self.warnings = warnings
    }
}

public struct ResolvedLaunchOptions: Equatable, Sendable {
    public var arguments: [String]
    public var model: String?
    public var reasoning: String?
    public var executionPolicy: WorkerExecutionPolicy

    public init(arguments: [String], model: String?, reasoning: String?, executionPolicy: WorkerExecutionPolicy) {
        self.arguments = arguments
        self.model = model
        self.reasoning = reasoning
        self.executionPolicy = executionPolicy
    }
}

/// Provider-specific launch option parsing and rewriting shared by UI and API launches.
/// Curated values are suggestions only; callers may provide any non-empty value.
public enum LaunchOptions {
    public static func modelSuggestions(for kind: CLIKind) -> [String] {
        switch kind {
        case .codex: ["gpt-6-astra", "gpt-5.4", "gpt-5.3-codex"]
        case .claude: ["opus", "sonnet", "haiku"]
        case .shell: []
        }
    }

    public static func reasoningSuggestions(for kind: CLIKind) -> [String] {
        switch kind {
        case .codex: ["low", "medium", "high", "xhigh"]
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        case .shell: []
        }
    }

    public static func rawArguments(for preset: AgentPreset) -> String {
        preset.rawArguments ?? ArgumentText.format(preset.arguments)
    }

    public static func inspect(rawArguments: String, kind: CLIKind) -> LaunchArgumentInspection {
        let arguments: [String]
        do { arguments = try ArgumentText.parse(rawArguments) }
        catch {
            return LaunchArgumentInspection(arguments: nil, model: nil, reasoning: nil, warnings: [
                "Launch arguments could not be parsed: \(error.localizedDescription). The text will still be saved; model and reasoning synchronization resumes after the syntax is repaired."
            ])
        }
        let model = occurrences(of: .model, in: arguments, kind: kind)
        let reasoning = occurrences(of: .reasoning, in: arguments, kind: kind)
        var warnings = model.warnings + reasoning.warnings
        do { try LaunchPolicy.validateArguments(arguments, kind: kind) }
        catch { warnings.append(error.localizedDescription) }
        return LaunchArgumentInspection(
            arguments: arguments,
            model: model.conflicting ? nil : model.values.first,
            reasoning: reasoning.conflicting ? nil : reasoning.values.first,
            warnings: unique(warnings)
        )
    }

    /// Rewrites all recognized occurrences of one option after the raw text parses.
    /// An empty value selects the provider default by removing that option.
    public static func updating(field: LaunchOptionField, value: String?, rawArguments: String, kind: CLIKind) throws -> String {
        var arguments = try ArgumentText.parse(rawArguments)
        arguments = removing(field, from: arguments, kind: kind)
        if let value, !value.isEmpty { arguments += canonical(field, value: value, kind: kind) }
        return ArgumentText.format(arguments)
    }

    public static func resolve(
        preset: AgentPreset,
        modelOverride: String? = nil,
        reasoningOverride: String? = nil,
        delegated: Bool = false
    ) throws -> ResolvedLaunchOptions {
        var arguments: [String]
        if let raw = preset.rawArguments { arguments = try ArgumentText.parse(raw) }
        else { arguments = preset.arguments }

        let initialModel = occurrences(of: .model, in: arguments, kind: preset.kind)
        let initialReasoning = occurrences(of: .reasoning, in: arguments, kind: preset.kind)
        if modelOverride == nil, initialModel.conflicting {
            throw ChauffeurError("conflicting_launch_option", "Launch arguments contain conflicting model options. Choose a model override or edit the preset")
        }
        if reasoningOverride == nil, initialReasoning.conflicting {
            throw ChauffeurError("conflicting_launch_option", "Launch arguments contain conflicting reasoning options. Choose a reasoning override or edit the preset")
        }
        if let modelOverride {
            arguments = removing(.model, from: arguments, kind: preset.kind)
            if !modelOverride.isEmpty { arguments += canonical(.model, value: modelOverride, kind: preset.kind) }
        }
        if let reasoningOverride {
            arguments = removing(.reasoning, from: arguments, kind: preset.kind)
            if !reasoningOverride.isEmpty { arguments += canonical(.reasoning, value: reasoningOverride, kind: preset.kind) }
        }
        if delegated { arguments = enforcingYOLO(in: arguments, kind: preset.kind) }
        try LaunchPolicy.validateArguments(arguments, kind: preset.kind)

        let model = occurrences(of: .model, in: arguments, kind: preset.kind).values.last
        let reasoning = occurrences(of: .reasoning, in: arguments, kind: preset.kind).values.last
        return ResolvedLaunchOptions(arguments: arguments, model: model, reasoning: reasoning, executionPolicy: delegated ? .delegatedYOLO : .standard)
    }

    private struct Occurrences {
        var values: [String] = []
        var warnings: [String] = []
        var conflicting: Bool { Set(values).count > 1 }
    }

    private static func occurrences(of field: LaunchOptionField, in arguments: [String], kind: CLIKind) -> Occurrences {
        var result = Occurrences(), index = 0
        while index < arguments.count {
            let match = recognized(arguments[index], field: field, kind: kind)
            switch match {
            case .none: break
            case .inline(let value): result.values.append(value)
            case .separate:
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                    result.warnings.append("\(arguments[index]) is missing its value")
                    index += 1
                    continue
                }
                let rawValue = arguments[index + 1]
                if kind == .codex, field == .reasoning {
                    guard rawValue.hasPrefix("model_reasoning_effort=") else { index += 2; continue }
                    result.values.append(String(rawValue.dropFirst("model_reasoning_effort=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
                } else { result.values.append(rawValue) }
                index += 1
            }
            index += 1
        }
        if result.conflicting {
            let label = field == .model ? "model" : "reasoning"
            result.warnings.append("Launch arguments contain conflicting \(label) values: \(result.values.joined(separator: ", "))")
        }
        return result
    }

    private enum Match { case none, separate, inline(String) }

    private static func recognized(_ argument: String, field: LaunchOptionField, kind: CLIKind) -> Match {
        switch (kind, field) {
        case (.codex, .model):
            if argument == "-m" || argument == "--model" { return .separate }
            if argument.hasPrefix("--model=") { return .inline(String(argument.dropFirst("--model=".count))) }
            if argument.hasPrefix("-m=") { return .inline(String(argument.dropFirst(3))) }
        case (.claude, .model):
            if argument == "--model" { return .separate }
            if argument.hasPrefix("--model=") { return .inline(String(argument.dropFirst("--model=".count))) }
        case (.codex, .reasoning):
            if argument == "-c" || argument == "--config" { return .separate }
            for prefix in ["-c=", "--config="] where argument.hasPrefix(prefix) {
                let config = String(argument.dropFirst(prefix.count))
                if config.hasPrefix("model_reasoning_effort=") { return .inline(String(config.dropFirst("model_reasoning_effort=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))) }
            }
        case (.claude, .reasoning):
            if argument == "--effort" { return .separate }
            if argument.hasPrefix("--effort=") { return .inline(String(argument.dropFirst("--effort=".count))) }
        case (.shell, _): break
        }
        return .none
    }

    private static func removing(_ field: LaunchOptionField, from arguments: [String], kind: CLIKind) -> [String] {
        var result: [String] = [], index = 0
        while index < arguments.count {
            let match = recognized(arguments[index], field: field, kind: kind)
            if case .none = match { result.append(arguments[index]) }
            else if case .separate = match, index + 1 < arguments.count {
                let next = arguments[index + 1]
                if kind == .codex, field == .reasoning, !next.hasPrefix("model_reasoning_effort=") {
                    if !next.hasPrefix("-") {
                        // This is an unrelated managed config pair. Preserve it
                        // verbatim; a reasoning picker edit owns only the
                        // model_reasoning_effort key.
                        result.append(arguments[index])
                        result.append(next)
                        index += 2
                    } else {
                        // An incomplete -c has no value to preserve. Leave the
                        // following option for the next iteration.
                        index += 1
                    }
                    continue
                }
                if !next.hasPrefix("-") { index += 1 }
            }
            index += 1
        }
        return result
    }

    private static func canonical(_ field: LaunchOptionField, value: String, kind: CLIKind) -> [String] {
        switch (kind, field) {
        case (.codex, .model), (.claude, .model): ["--model", value]
        case (.codex, .reasoning): ["-c", "model_reasoning_effort=\(value)"]
        case (.claude, .reasoning): ["--effort", value]
        case (.shell, _): []
        }
    }

    private static func enforcingYOLO(in arguments: [String], kind: CLIKind) -> [String] {
        let valueOptions: Set<String>
        let flagOptions: Set<String>
        let enforced: String
        switch kind {
        case .codex:
            valueOptions = ["-s", "--sandbox", "-a", "--ask-for-approval"]
            flagOptions = ["--approve-for-me", "--dangerously-bypass-approvals-and-sandbox", "--yolo"]
            enforced = "--dangerously-bypass-approvals-and-sandbox"
        case .claude:
            valueOptions = ["--permission-mode"]
            flagOptions = ["--allow-dangerously-skip-permissions", "--dangerously-skip-permissions"]
            enforced = "--dangerously-skip-permissions"
        case .shell: return arguments
        }
        var result: [String] = [], index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let key = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            if flagOptions.contains(key) { index += 1; continue }
            if valueOptions.contains(key) {
                if !argument.contains("="), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") { index += 1 }
                index += 1; continue
            }
            result.append(argument); index += 1
        }
        result.append(enforced)
        return result
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

public extension LaunchSnapshot {
    /// Old snapshots predate structured model choices; resolve display from the
    /// arguments that actually launched, never from the current editable preset.
    var displayedModel: String? { selectedModel ?? displayOptions.model }
    var displayedReasoning: String? { selectedReasoning ?? displayOptions.reasoning }
    private var displayOptions: LaunchArgumentInspection {
        let raw = resolvedArguments.map(ArgumentText.format) ?? LaunchOptions.rawArguments(for: preset)
        return LaunchOptions.inspect(rawArguments: raw, kind: preset.kind)
    }
}
