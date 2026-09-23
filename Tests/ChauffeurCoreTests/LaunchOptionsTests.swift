import Foundation
import Testing
import ChauffeurCore

struct LaunchOptionsTests {
    private func preset(_ kind: CLIKind, arguments: [String] = [], raw: String? = nil) -> AgentPreset {
        var preset = AgentPreset(setID: UUID(), name: "Fixture", kind: kind, executable: kind.rawValue, configurationDirectory: "/tmp")
        preset.arguments = arguments
        preset.rawArguments = raw
        return preset
    }

    @Test func orchestrationRoleModelsAreAdvertisedByLaunchSuggestions() throws {
        let skill = try CoordinationSkill.bundled(named: CoordinationSkill.orchestratorName)
        let suggestions = Set(LaunchOptions.modelSuggestions(for: .codex))
        for (path, data) in skill.referenceFiles {
            let text = String(decoding: data, as: UTF8.self)
            let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("Suggested model:") })
            let model = try #require(line.split(separator: "`").dropFirst().first)
            #expect(suggestions.contains(String(model)), "Missing model suggestion for \(path)")
        }
    }

    @Test func aCustomModelNameIsNotMistakenForAReasoningOption() throws {
        let raw = "--model model_reasoning_effort=custom"
        let edited = try LaunchOptions.updating(field: .reasoning, value: "high", rawArguments: raw, kind: .codex)
        #expect(try ArgumentText.parse(edited) == ["--model", "model_reasoning_effort=custom", "-c", "model_reasoning_effort=high"])
        #expect(LaunchOptions.inspect(rawArguments: raw, kind: .codex).reasoning == nil)
    }

    @Test func legacySnapshotDisplayUsesLaunchArgumentsAndHonorsClearedOverrides() throws {
        let team = PresetSet(name: "Fixture")
        var preset = AgentPreset(setID: team.id, name: "Claude", kind: .claude, executable: "claude", configurationDirectory: "/tmp")
        preset.arguments = ["--model", "opus", "--effort", "high"]
        var snapshot = LaunchSnapshot(preset: preset, set: team, executablePath: "/tmp/claude", executableVersion: "old", workingDirectory: "/tmp", additionalPaths: [])
        #expect(snapshot.displayedModel == "opus" && snapshot.displayedReasoning == "high")
        snapshot.resolvedArguments = []
        #expect(snapshot.displayedModel == nil && snapshot.displayedReasoning == nil)
    }

    @Test func recognizedOptionsPopulateControlsAndEditsPreserveOtherArguments() throws {
        let raw = "--verbose --model 'private model' --effort=xhigh"
        let inspection = LaunchOptions.inspect(rawArguments: raw, kind: .claude)
        #expect(inspection.model == "private model")
        #expect(inspection.reasoning == "xhigh")
        #expect(inspection.warnings.isEmpty)

        let edited = try LaunchOptions.updating(field: .model, value: "custom", rawArguments: raw, kind: .claude)
        #expect(try ArgumentText.parse(edited) == ["--verbose", "--effort=xhigh", "--model", "custom"])
        let providerDefault = try LaunchOptions.updating(field: .reasoning, value: nil, rawArguments: edited, kind: .claude)
        #expect(try ArgumentText.parse(providerDefault) == ["--verbose", "--model", "custom"])

        let repaired = try LaunchOptions.updating(field: .model, value: "sonnet", rawArguments: "--model --verbose", kind: .claude)
        #expect(try ArgumentText.parse(repaired) == ["--verbose", "--model", "sonnet"])

        let unrelatedConfig = try LaunchOptions.updating(field: .reasoning, value: "high", rawArguments: "-c foo=bar --model gpt-x", kind: .codex)
        #expect(try ArgumentText.parse(unrelatedConfig) == ["-c", "foo=bar", "--model", "gpt-x", "-c", "model_reasoning_effort=high"])
    }

    @Test func conflictsAndMalformedTextWarnWithoutBlockingPresetValidation() throws {
        let conflict = LaunchOptions.inspect(rawArguments: "--model opus --model sonnet", kind: .claude)
        #expect(conflict.model == nil)
        #expect(conflict.warnings.contains { $0.contains("conflicting model") })

        let malformed = preset(.codex, arguments: ["--model", "stale"], raw: "--model 'unfinished")
        try malformed.validate()
        let inspection = LaunchOptions.inspect(rawArguments: malformed.rawArguments!, kind: malformed.kind)
        #expect(inspection.arguments == nil)
        #expect(inspection.warnings.contains { $0.contains("will still be saved") })
        #expect(throws: ChauffeurError.self) { try LaunchOptions.resolve(preset: malformed) }
    }

    @Test func legacyArgumentsAndRawTextDecodeCompatibly() throws {
        let legacy = preset(.claude, arguments: ["--model", "sonnet"])
        let decoded = try JSONCoding.decode(AgentPreset.self, from: JSONCoding.encode(legacy))
        #expect(decoded.rawArguments == nil)
        #expect(try LaunchOptions.resolve(preset: decoded).model == "sonnet")

        let raw = preset(.claude, arguments: ["--model", "stale"], raw: "--model opus")
        #expect(try LaunchOptions.resolve(preset: raw).model == "opus")
    }

    @Test func overridesReplaceConflictsAndDoNotMutatePreset() throws {
        let original = preset(.claude, arguments: ["--verbose"], raw: "--verbose --model opus --model sonnet --effort low")
        let resolved = try LaunchOptions.resolve(preset: original, modelOverride: "private-model", reasoningOverride: "max")
        #expect(resolved.arguments == ["--verbose", "--model", "private-model", "--effort", "max"])
        #expect(resolved.model == "private-model")
        #expect(resolved.reasoning == "max")
        #expect(original.rawArguments == "--verbose --model opus --model sonnet --effort low")
    }

    @Test func delegatedLaunchNormalizesProviderPolicy() throws {
        let codex = preset(.codex, raw: "--model custom -c model_reasoning_effort=high --sandbox read-only --ask-for-approval on-request --approve-for-me")
        let codexResolved = try LaunchOptions.resolve(preset: codex, delegated: true)
        #expect(codexResolved.arguments == ["--model", "custom", "-c", "model_reasoning_effort=high", "--dangerously-bypass-approvals-and-sandbox"])
        #expect(codexResolved.reasoning == "high")
        #expect(codexResolved.executionPolicy == .delegatedYOLO)

        let claude = preset(.claude, raw: "--model=opus --permission-mode plan --allow-dangerously-skip-permissions")
        let claudeResolved = try LaunchOptions.resolve(preset: claude, delegated: true)
        #expect(claudeResolved.arguments == ["--model=opus", "--dangerously-skip-permissions"])
        #expect(claudeResolved.executionPolicy == .delegatedYOLO)
    }

    @Test func onlyTheDedicatedCodexReasoningConfigIsAccepted() throws {
        try LaunchPolicy.validateArguments(["--config=model_reasoning_effort=high"], kind: .codex)
        try LaunchPolicy.validateArguments(["-c", "model_reasoning_effort=xhigh"], kind: .codex)
        #expect(throws: ChauffeurError.self) {
            try LaunchPolicy.validateArguments(["--config=notify=contains-model_reasoning_effort=high"], kind: .codex)
        }
        #expect(throws: ChauffeurError.self) {
            try LaunchPolicy.validateArguments(["-c", "notify=contains-model_reasoning_effort=high"], kind: .codex)
        }
    }

    @Test func requestAndSnapshotNewFieldsAreBackwardCompatible() throws {
        let requestData = Data(#"{"projectID":"00000000-0000-0000-0000-000000000001","groupID":"00000000-0000-0000-0000-000000000002","presetID":"00000000-0000-0000-0000-000000000003","folderID":"00000000-0000-0000-0000-000000000004","additionalFolderIDs":[],"title":"Legacy","allowSharedCheckout":false,"coordinationEnabled":false,"retryKey":"00000000-0000-0000-0000-000000000005"}"#.utf8)
        let request = try JSONCoding.decode(LaunchRequest.self, from: requestData)
        #expect(request.modelOverride == nil && request.reasoningOverride == nil)

        let set = PresetSet(name: "Fixture")
        let launch = LaunchSnapshot(preset: preset(.codex), set: set, executablePath: "/bin/false", executableVersion: "fixture", workingDirectory: "/tmp", additionalPaths: [])
        let decoded = try JSONCoding.decode(LaunchSnapshot.self, from: JSONCoding.encode(launch))
        #expect(decoded.resolvedArguments == nil)
        #expect(decoded.executionPolicy == nil)
    }

    private func autoApprove(_ raw: String, _ kind: CLIKind) -> Bool { LaunchOptions.inspect(rawArguments: raw, kind: kind).autoApprove }
    private func setting(_ on: Bool, _ raw: String, _ kind: CLIKind) throws -> [String] {
        try ArgumentText.parse(LaunchOptions.updatingAutoApprove(on, rawArguments: raw, kind: kind))
    }

    @Test func autoApproveIsRecognizedInEveryProviderForm() {
        #expect(autoApprove("--dangerously-skip-permissions", .claude))
        #expect(autoApprove("--permission-mode bypassPermissions", .claude))
        #expect(autoApprove("--permission-mode=bypassPermissions", .claude))
        #expect(!autoApprove("--permission-mode plan", .claude))
        #expect(!autoApprove("--permission-mode=acceptEdits", .claude))
        #expect(!autoApprove("--allow-dangerously-skip-permissions", .claude))
        #expect(!autoApprove("--yolo", .claude))
        #expect(autoApprove("--dangerously-bypass-approvals-and-sandbox", .codex))
        #expect(autoApprove("--search --yolo", .codex))
        #expect(!autoApprove("--sandbox danger-full-access --approve-for-me", .codex))
        #expect(!autoApprove("--dangerously-skip-permissions", .codex))
        #expect(!autoApprove("--dangerously-skip-permissions", .shell))
        #expect(!autoApprove("--model 'unfinished", .claude))
        #expect(LaunchOptions.autoApproveCaption(for: .claude) == "Skips permission prompts")
        #expect(LaunchOptions.autoApproveCaption(for: .codex) == "Skips approvals and the sandbox")
        #expect(LaunchOptions.autoApproveCaption(for: .shell) == nil)
    }

    @Test func checkingAutoApproveAddsTheCanonicalFlagOnce() throws {
        #expect(try setting(true, "--model opus", .claude) == ["--model", "opus", "--dangerously-skip-permissions"])
        #expect(try setting(true, "--permission-mode bypassPermissions", .claude) == ["--permission-mode", "bypassPermissions"])
        #expect(try setting(true, "--permission-mode plan", .claude) == ["--permission-mode", "plan", "--dangerously-skip-permissions"])
        #expect(try setting(true, "--yolo", .codex) == ["--yolo"])
        #expect(try setting(true, "--search", .codex) == ["--search", "--dangerously-bypass-approvals-and-sandbox"])
        #expect(try setting(true, "-l", .shell) == ["-l"])
        let viaField = try LaunchOptions.updating(field: .autoApprove, value: "true", rawArguments: "", kind: .codex)
        #expect(try ArgumentText.parse(viaField) == ["--dangerously-bypass-approvals-and-sandbox"])
    }

    @Test func uncheckingAutoApproveRemovesEveryRecognizedForm() throws {
        let claude = "--dangerously-skip-permissions --verbose --permission-mode bypassPermissions --permission-mode=bypassPermissions --allow-dangerously-skip-permissions"
        #expect(try setting(false, claude, .claude) == ["--verbose", "--allow-dangerously-skip-permissions"])
        #expect(try setting(false, "--permission-mode plan --dangerously-skip-permissions", .claude) == ["--permission-mode", "plan"])
        #expect(try setting(false, "--permission-mode=acceptEdits", .claude) == ["--permission-mode=acceptEdits"])
        #expect(try setting(false, "--yolo --search --dangerously-bypass-approvals-and-sandbox --approve-for-me", .codex) == ["--search", "--approve-for-me"])
        let viaField = try LaunchOptions.updating(field: .autoApprove, value: nil, rawArguments: "--yolo", kind: .codex)
        #expect(viaField.isEmpty)
    }

    @Test func autoApproveRoundTripsThroughTheArgumentsText() throws {
        for kind in [CLIKind.claude, .codex] {
            let on = try LaunchOptions.updatingAutoApprove(true, rawArguments: "--model m", kind: kind)
            #expect(LaunchOptions.inspect(rawArguments: on, kind: kind).autoApprove)
            let off = try LaunchOptions.updatingAutoApprove(false, rawArguments: on, kind: kind)
            #expect(!LaunchOptions.inspect(rawArguments: off, kind: kind).autoApprove)
            #expect(try ArgumentText.parse(off) == ["--model", "m"])
        }
        #expect(throws: (any Error).self) { try LaunchOptions.updatingAutoApprove(true, rawArguments: "--model 'unfinished", kind: .claude) }
    }

    @Test func autoApproveOverrideAppliesToTheSessionOnly() throws {
        let claude = preset(.claude, raw: "--model opus --permission-mode bypassPermissions")
        #expect(try LaunchOptions.resolve(preset: claude).arguments == ["--model", "opus", "--permission-mode", "bypassPermissions"])
        #expect(try LaunchOptions.resolve(preset: claude, autoApproveOverride: false).arguments == ["--model", "opus"])
        #expect(try LaunchOptions.resolve(preset: claude, autoApproveOverride: true).arguments == ["--model", "opus", "--permission-mode", "bypassPermissions"])
        let codex = preset(.codex, raw: "--search")
        #expect(try LaunchOptions.resolve(preset: codex, modelOverride: "gpt-x", autoApproveOverride: true).arguments == ["--search", "--model", "gpt-x", "--dangerously-bypass-approvals-and-sandbox"])
        #expect(codex.rawArguments == "--search")
    }

    @Test func delegatedWorkersAutoApproveWhateverTheOverrideSays() throws {
        let claude = try LaunchOptions.resolve(preset: preset(.claude, raw: "--permission-mode plan"), autoApproveOverride: false, delegated: true)
        #expect(claude.arguments == ["--dangerously-skip-permissions"])
        let codex = try LaunchOptions.resolve(preset: preset(.codex, raw: "--yolo"), autoApproveOverride: true, delegated: true)
        #expect(codex.arguments == ["--dangerously-bypass-approvals-and-sandbox"])
        #expect(codex.executionPolicy == .delegatedYOLO)
    }

    @Test func autoApproveOverrideIsOptionalInLaunchRequests() throws {
        var request = LaunchRequest(projectID: UUID(), groupID: UUID(), presetID: UUID(), folderID: UUID(), title: "T")
        #expect(!String(decoding: try JSONCoding.encode(request), as: UTF8.self).contains("autoApproveOverride"))
        request.autoApproveOverride = false
        #expect(try JSONCoding.decode(LaunchRequest.self, from: JSONCoding.encode(request)).autoApproveOverride == false)
    }
}
