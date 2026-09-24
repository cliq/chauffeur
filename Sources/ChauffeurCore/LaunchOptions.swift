import Foundation

public enum LaunchOptionField: Equatable, Sendable {
    case model, reasoning, autoApprove
}

public enum WorkerExecutionPolicy: String, Codable, Sendable {
    case standard
    case delegatedYOLO
}

public struct LaunchArgumentInspection: Equatable, Sendable {
    public var arguments: [String]?
    public var model: String?
    public var reasoning: String?
    public var autoApprove: Bool
    public var warnings: [String]

    public init(arguments: [String]?, model: String?, reasoning: String?, autoApprove: Bool = false, warnings: [String]) {
        self.arguments = arguments
        self.model = model
        self.reasoning = reasoning
        self.autoApprove = autoApprove
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
    /// Curated values, then what a probing provider listed (`ModelSuggestionCache`)
    /// for any of its executables and configurations.
    public static func modelSuggestions(for kind: CLIKind) -> [String] {
        guard let provider = kind.provider else { return [] }
        return provider.modelSuggestions + (provider.probesModels ? ModelSuggestionCache.models(kind: kind) : [])
    }
    public static func reasoningSuggestions(for kind: CLIKind) -> [String] { kind.provider?.reasoningSuggestions ?? [] }
    /// nil for kinds without an auto-approve mode.
    public static func autoApproveCaption(for kind: CLIKind) -> String? { kind.provider?.autoApprove.caption }

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
            autoApprove: autoApproves(arguments, kind: kind),
            warnings: unique(warnings)
        )
    }

    /// Rewrites all recognized occurrences of one option after the raw text parses.
    /// An empty value selects the provider default by removing that option.
    /// For `.autoApprove`, any non-empty value turns it on.
    public static func updating(field: LaunchOptionField, value: String?, rawArguments: String, kind: CLIKind) throws -> String {
        if field == .autoApprove { return try updatingAutoApprove(value?.isEmpty == false, rawArguments: rawArguments, kind: kind) }
        var arguments = try ArgumentText.parse(rawArguments)
        arguments = removing(field, from: arguments, kind: kind)
        if let value, !value.isEmpty { arguments += canonical(field, value: value, kind: kind) }
        return ArgumentText.format(arguments)
    }

    /// Turning on replaces the provider's approval and sandbox options with the
    /// canonical flag (the CLIs refuse them together) unless a recognized form is
    /// already present; turning off removes every recognized form.
    public static func updatingAutoApprove(_ on: Bool, rawArguments: String, kind: CLIKind) throws -> String {
        ArgumentText.format(settingAutoApprove(on, in: try ArgumentText.parse(rawArguments), kind: kind))
    }

    public static func resolve(
        preset: AgentPreset,
        modelOverride: String? = nil,
        reasoningOverride: String? = nil,
        autoApproveOverride: Bool? = nil,
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
        if let autoApproveOverride { arguments = settingAutoApprove(autoApproveOverride, in: arguments, kind: preset.kind) }
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
            switch recognized(arguments[index], field: field, kind: kind) {
            case .none: break
            case .inline(let value): result.values.append(value)
            case .separate:
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                    result.warnings.append("\(arguments[index]) is missing its value")
                    index += 1
                    continue
                }
                guard let value = kind.provider?.separateValue(arguments[index + 1], field: field) else { index += 2; continue }
                result.values.append(value)
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

    private static func recognized(_ argument: String, field: LaunchOptionField, kind: CLIKind) -> LaunchOptionMatch {
        kind.provider?.recognize(argument, field: field) ?? .none
    }

    private static func removing(_ field: LaunchOptionField, from arguments: [String], kind: CLIKind) -> [String] {
        var result: [String] = [], index = 0
        while index < arguments.count {
            let match = recognized(arguments[index], field: field, kind: kind)
            if case .none = match { result.append(arguments[index]) }
            else if case .separate = match, index + 1 < arguments.count {
                let next = arguments[index + 1]
                if !next.hasPrefix("-") {
                    // A pair that belongs to another setting (an unrelated Codex
                    // `-c key=value`) is preserved verbatim.
                    if kind.provider?.separateValue(next, field: field) == nil {
                        result.append(arguments[index]); result.append(next)
                    }
                    index += 1
                }
            }
            index += 1
        }
        return result
    }

    private static func canonical(_ field: LaunchOptionField, value: String, kind: CLIKind) -> [String] {
        kind.provider?.canonical(field, value: value) ?? []
    }

    private enum AutoApproveForm { case none, flag, inline, separate }

    private static func autoApproveForm(_ arguments: [String], at index: Int, policy: AutoApprovePolicy) -> AutoApproveForm {
        let argument = arguments[index]
        if argument == policy.flag || policy.alternateFlags.contains(argument) { return .flag }
        for (option, value) in policy.enablingValues {
            if argument == option + "=" + value { return .inline }
            if argument == option, arguments.dropFirst(index + 1).first == value { return .separate }
        }
        return .none
    }

    private static func autoApproves(_ arguments: [String], kind: CLIKind) -> Bool {
        guard let policy = kind.provider?.autoApprove else { return false }
        return arguments.indices.contains { autoApproveForm(arguments, at: $0, policy: policy) != .none }
    }

    private static func settingAutoApprove(_ on: Bool, in arguments: [String], kind: CLIKind) -> [String] {
        guard let policy = kind.provider?.autoApprove else { return arguments }
        if on { return autoApproves(arguments, kind: kind) ? arguments : enforcingYOLO(in: arguments, kind: kind) }
        var result: [String] = [], index = 0
        while index < arguments.count {
            switch autoApproveForm(arguments, at: index, policy: policy) {
            case .none: result.append(arguments[index])
            case .flag, .inline: break
            case .separate: index += 1
            }
            index += 1
        }
        return result
    }

    private static func enforcingYOLO(in arguments: [String], kind: CLIKind) -> [String] {
        guard let policy = kind.provider?.autoApprove else { return arguments }
        var result: [String] = [], index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let key = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            if policy.replacedFlags.contains(key) { index += 1; continue }
            if policy.replacedValueOptions.contains(key) {
                if !argument.contains("="), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") { index += 1 }
                index += 1; continue
            }
            result.append(argument); index += 1
        }
        result.append(policy.flag)
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
