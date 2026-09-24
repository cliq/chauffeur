import Foundation
import Testing
import ChauffeurCore

struct OpenCodeProviderTests {
    private let provider = OpenCodeProvider()
    private func validation(_ arguments: [String]) -> String? {
        do { try LaunchPolicy.validateArguments(arguments, kind: .opencode); return nil }
        catch let error as ChauffeurError { return error.code } catch { return "unexpected" }
    }
    private func preset(raw: String) -> AgentPreset {
        var preset = AgentPreset(setID: UUID(), name: "Fixture", kind: .opencode, executable: "opencode", configurationDirectory: "/tmp")
        preset.rawArguments = raw
        return preset
    }

    @Test func identityAndPresentation() {
        #expect(CLIKind(rawValue: "opencode") == .opencode && CLIKind.opencode.provider?.kind == .opencode)
        #expect(CLIKind.opencode.displayName == "OpenCode" && provider.badgeColorName == "teal")
        #expect(provider.installURL.absoluteString == "https://opencode.ai")
        #expect(AgentProviders.all.map(\.kind) == [.codex, .claude, .opencode])
        #expect(provider.supportsReasoning == false && provider.preassignsConversationID == false)
        #expect(provider.wakeStrategy == .plugin && provider.maxInboxWaitSeconds == 240)
        #expect(provider.skillDiscovery == .sharedAgentsHome && provider.probesModels)
        #expect(ClaudeProvider().maxInboxWaitSeconds == nil && CodexProvider().maxInboxWaitSeconds == nil)
    }

    @Test func identificationNeedsSemverAndOpenCodeHelp() {
        let help = "Commands:\n  opencode acp   start ACP\n  opencode serve   starts a headless opencode server\n"
        for version in ["1.18.32", "0.0.1", "10.2.3-beta.1"] {
            #expect(provider.identifies(version: version), "\(version)")
            #expect(provider.identifies(version: version, help: help), "\(version)")
        }
        for version in ["1.18", "v1.18.32", "1.18.x", "codex-cli 1.2.3", "2.1.272 (Claude Code)", ""] {
            #expect(!provider.identifies(version: version), "\(version)")
        }
        #expect(!provider.identifies(version: "1.18.32", help: "Usage: other-tool serve"))
        // Claude and Codex keep version-only identification.
        #expect(ClaudeProvider().identifies(version: "2.1.272 (Claude Code)", help: ""))
    }

    @Test func argumentPolicy() {
        for allowed in [["-m", "local/qwen"], ["--model", "local/qwen"], ["--model=local/qwen"], ["-m=local/qwen"], ["--agent", "plan"],
                        ["--auto"], ["--log-level", "DEBUG"], ["--print-logs"]] {
            #expect(validation(allowed) == nil, "\(allowed)")
        }
        for managed in ["-c", "--continue", "-s", "--session", "--fork", "--prompt", "--port", "--hostname", "--mdns", "--mdns-domain", "--cors",
                        "--pure", "--mini", "--no-replay", "--replay-limit", "--add-dir", "--"] {
            #expect(validation([managed, "x"]) == "managed_argument", "\(managed)")
            #expect(validation([managed + "=x"]) == "managed_argument", "\(managed)=")
        }
        #expect(validation(["-sses_x"]) == "managed_argument" && validation(["-cfoo"]) == "managed_argument")
        // Subcommands and the project positional are not options.
        for rejected in [["serve"], ["run", "hello"], ["/tmp/project"], ["--dangerously-skip-permissions"], ["-m"], ["--auto=1"]] {
            #expect(validation(rejected) == "invalid", "\(rejected)")
        }
    }

    @Test func launchOptionsAndAutoApprove() throws {
        let inspection = LaunchOptions.inspect(rawArguments: "-m local/qwen --auto", kind: .opencode)
        #expect(inspection.model == "local/qwen" && inspection.reasoning == nil && inspection.autoApprove && inspection.warnings.isEmpty)
        #expect(try LaunchOptions.updating(field: .model, value: "opencode/big-pickle", rawArguments: "-m local/qwen --agent plan", kind: .opencode) == "--agent plan --model opencode/big-pickle")
        #expect(try LaunchOptions.updating(field: .reasoning, value: "high", rawArguments: "--agent plan", kind: .opencode) == "--agent plan")
        #expect(try LaunchOptions.updatingAutoApprove(true, rawArguments: "--agent plan", kind: .opencode) == "--agent plan --auto")
        #expect(try LaunchOptions.updatingAutoApprove(false, rawArguments: "--auto --agent plan", kind: .opencode) == "--agent plan")
        #expect(LaunchOptions.autoApproveCaption(for: .opencode) == "Approves anything not explicitly denied")
        #expect(LaunchOptions.reasoningSuggestions(for: .opencode).isEmpty)

        let off = try LaunchOptions.resolve(preset: preset(raw: "--model local/qwen"), autoApproveOverride: false)
        #expect(off.arguments == ["--model", "local/qwen"] && off.model == "local/qwen")
        let on = try LaunchOptions.resolve(preset: preset(raw: "--model local/qwen"), autoApproveOverride: true)
        #expect(on.arguments == ["--model", "local/qwen", "--auto"])
        let delegated = try LaunchOptions.resolve(preset: preset(raw: "--auto --agent build"), modelOverride: "local/other", autoApproveOverride: false, delegated: true)
        #expect(delegated.arguments == ["--agent", "build", "--model", "local/other", "--auto"] && delegated.executionPolicy == .delegatedYOLO)
    }

    @Test func configurationDirectoryIsSelectedOnlyWhenNotTheGlobalOne() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(provider.defaultConfigurationDirectory(home: "/Users/me") == "/Users/me/.config/opencode")
        #expect(provider.environment(configurationDirectory: home + "/.config/opencode").isEmpty)
        #expect(provider.environment(configurationDirectory: "/team/opencode") == ["OPENCODE_CONFIG_DIR": "/team/opencode"])
        var team = PresetSet(name: "Fixture")
        #expect(team.configurationEnvironment["OPENCODE_CONFIG_DIR"] == nil)
        team.configurationDirectories = ["opencode": "/team/opencode"]
        #expect(team.configurationEnvironment["OPENCODE_CONFIG_DIR"] == Paths.canonical("/team/opencode"))
    }

    @Test func inheritedOpenCodeStateIsStripped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-opencode-env-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ["PATH": "/bin", "OPENCODE_CONFIG_CONTENT": "{}", "OPENCODE_CONFIG_DIR": "/parent", "OPENCODE": "1", "OPENAI_API_KEY": "secret", "ANTHROPIC_API_KEY": "secret"]
        var preset = AgentPreset(setID: UUID(), name: "Fixture", kind: .opencode, executable: "opencode", configurationDirectory: root.path)
        let environment = try LaunchPolicy.environment(base: base, preset: preset, projectID: UUID(), sessionID: UUID(), token: "t")
        #expect(environment["OPENCODE_CONFIG_DIR"] == Paths.canonical(root.path))
        #expect(environment["OPENCODE_CONFIG_CONTENT"] == nil && environment["OPENCODE"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil && environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["CHAUFFEUR_SESSION_TOKEN"] == "t" && environment["CHAUFFEUR_SESSION_ID"] != nil)
        preset.configurationDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode").path
        let global = try LaunchPolicy.environment(base: base, preset: preset, projectID: UUID(), sessionID: UUID(), token: "t", allowMissingConfiguration: true)
        #expect(global["OPENCODE_CONFIG_DIR"] == nil)
    }

    @Test func conversationIDs() {
        let id = "ses_" + String(repeating: "aB3", count: 8) + "xy"
        #expect(id.count == 30 && provider.validatesConversationID(id))
        for bad in ["ses_short", id + "z", "ses_" + String(repeating: "-", count: 26), UUID().uuidString, "SES_" + id.dropFirst(4)] {
            #expect(!provider.validatesConversationID(bad), "\(bad)")
        }
        #expect(NativeConversation.same(id, id) && !NativeConversation.same(id, id.lowercased()) && !NativeConversation.same(id, nil))
        #expect(!NativeConversation.same("x", "x"))
        let payload = HookPayload.parse(Data(#"{"session_id":"\#(id)","hook_event_name":"SessionStart","source":"startup"}"#.utf8))
        #expect(payload == HookPayload(hookEvent: "SessionStart", source: "startup", conversationID: id))
        #expect(HookPayload.parse(Data(#"{"session_id":"ses_nope"}"#.utf8)).conversationID == nil)
        // The plugin reports only the first root session.
        #expect(!NativeConversation.adopts(kind: .opencode, hookEvent: "SessionStart", source: "startup"))
        #expect(NativeConversation.adoptsFirst(kind: .opencode, hooksTrusted: true, hookEvent: nil))
    }

    @Test func inboxHookOutputForThePlugin() throws {
        func decode(_ data: Data?) throws -> JSONValue { try JSONCoding.decode(JSONValue.self, from: #require(data)) }
        let blocked = try decode(InboxHintFormatter.openCodeOutput(event: "Stop", summary: InboxHintSummary(count: 2, results: 1, block: true, waitForWorkers: true)))
        #expect(blocked == .object(["block": .bool(true), "text": .string(InboxHintFormatter.text(InboxHintSummary(count: 2, results: 1))), "waitForWorkers": .bool(false)]))
        let idle = try decode(InboxHintFormatter.openCodeOutput(event: "Stop", summary: InboxHintSummary(waitForWorkers: true)))
        #expect(idle == .object(["block": .bool(false), "text": .null, "waitForWorkers": .bool(true)]))
        let quiet = try decode(InboxHintFormatter.openCodeOutput(event: "Stop", summary: InboxHintSummary()))
        #expect(quiet == .object(["block": .bool(false), "text": .null, "waitForWorkers": .bool(false)]))
        let tool = try decode(InboxHintFormatter.openCodeOutput(event: "PostToolUse", summary: InboxHintSummary(count: 1, waitForWorkers: true)))
        #expect(tool == .object(["block": .bool(false), "text": .string(InboxHintFormatter.text(InboxHintSummary(count: 1))), "waitForWorkers": .bool(false)]))
        let line = String(decoding: try #require(InboxHintFormatter.openCodeOutput(event: "Stop", summary: InboxHintSummary())), as: UTF8.self)
        #expect(!line.contains("\n"))
        // Claude and Codex output ignores the new field.
        #expect(InboxHintFormatter.output(event: "Stop", summary: InboxHintSummary(waitForWorkers: true)) == nil)
    }

    @Test func waitForWorkJSON() throws {
        var report = WorkReport(reason: .timeout); report.timeoutMinutes = 5
        let value = try JSONCoding.decode(JSONValue.self, from: Data(WorkReportFormatter.json(report).utf8))
        #expect(value == .object(["reason": .string("timeout"), "text": .string(WorkReportFormatter.text(report))]))
        #expect(!WorkReportFormatter.json(WorkReport(reason: .work)).contains("\n"))
    }

    @Test func modelSuggestionCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-models-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = ModelSuggestionCache.url(root: root)
        #expect(ModelSuggestionCache.models(kind: .opencode, at: url).isEmpty)
        try ModelSuggestionCache.store(["a/1", "a/1", "b/2"], kind: .opencode, executable: "/bin/opencode", configurationDirectory: "", at: url)
        try ModelSuggestionCache.store(["c/3"], kind: .opencode, executable: "/bin/opencode", configurationDirectory: "/team", at: url)
        #expect(ModelSuggestionCache.models(kind: .opencode, executable: "/bin/opencode", configurationDirectory: "", at: url) == ["a/1", "b/2"])
        #expect(ModelSuggestionCache.models(kind: .opencode, executable: "/bin/opencode", configurationDirectory: "/team", at: url) == ["c/3"])
        #expect(Set(ModelSuggestionCache.models(kind: .opencode, at: url)) == ["a/1", "b/2", "c/3"])
        try ModelSuggestionCache.store(["d/4"], kind: .opencode, executable: "/bin/opencode", configurationDirectory: "", at: url)
        #expect(ModelSuggestionCache.models(kind: .opencode, executable: "/bin/opencode", configurationDirectory: "", at: url) == ["d/4"])
        #expect(ModelSuggestionCache.models(kind: .codex, at: url).isEmpty)
    }

    @Test func pluginIsBundled() throws {
        let source = String(decoding: try OpenCodePlugin.bundledSource(), as: UTF8.self)
        #expect(source.contains("ChauffeurOpenCode"))
    }

    @Test func basePresetIsSeededAndAddedOnceToExistingCatalogs() async throws {
        func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-opencode-seed-\(UUID())") }
        let fresh = root(); defer { try? FileManager.default.removeItem(at: fresh) }
        let store = try FileStore(root: fresh)
        try await store.migrateTeamAgents()
        let seeded = await store.reload().baseAgentPresets.map(\.value)
        #expect(Set(seeded.map(\.kind)) == [.claude, .codex, .opencode])
        #expect(seeded.first { $0.kind == .opencode }.map { ($0.name, $0.executable) } ?? ("", "") == ("OpenCode", "opencode"))

        // An install from before OpenCode gains it once, even after the user removes it again.
        let existing = root(); defer { try? FileManager.default.removeItem(at: existing) }
        let old = try FileStore(root: existing)
        try await old.save(BaseAgentPreset(name: "Claude", kind: .claude, executable: "claude"))
        let marker = existing.appendingPathComponent("migrations/team-agents-v2/complete.json")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":2}".utf8).write(to: marker)
        try await old.migrateTeamAgents()
        let added = try #require(await old.reload().baseAgentPresets.first { $0.value.kind == .opencode })
        var archived = added.value; archived.archived = true
        try await old.save(archived, expectedVersion: added.version)
        try await old.migrateTeamAgents()
        #expect(await old.reload().baseAgentPresets.filter { $0.value.kind == .opencode }.map(\.value.archived) == [true])

        // A catalog the user emptied stays empty.
        let emptied = root(); defer { try? FileManager.default.removeItem(at: emptied) }
        let empty = try FileStore(root: emptied)
        var codex = BaseAgentPreset(name: "Codex", kind: .codex, executable: "codex"); codex.archived = true
        try await empty.save(codex)
        try FileManager.default.createDirectory(at: emptied.appendingPathComponent("migrations/team-agents-v2"), withIntermediateDirectories: true)
        try Data("{\"version\":2}".utf8).write(to: emptied.appendingPathComponent("migrations/team-agents-v2/complete.json"))
        try await empty.migrateTeamAgents()
        #expect(!(await empty.reload().baseAgentPresets.contains { $0.value.kind == .opencode }))
    }
}
