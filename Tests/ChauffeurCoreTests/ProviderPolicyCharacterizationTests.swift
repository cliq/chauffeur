import Foundation
import Testing
import ChauffeurCore

/// Pins Claude and Codex argument grammar, launch environment and launch-option
/// rewriting exactly as they behave today.
struct ProviderPolicyCharacterizationTests {
    private func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let error as ChauffeurError { return error.code } catch { return "unexpected" }
    }
    private func validation(_ arguments: [String], _ kind: CLIKind) -> String? { code { try LaunchPolicy.validateArguments(arguments, kind: kind) } }
    private func preset(_ kind: CLIKind, raw: String, directory: String = "/tmp") -> AgentPreset {
        var preset = AgentPreset(setID: UUID(), name: "Fixture", kind: kind, executable: kind.rawValue, configurationDirectory: directory)
        preset.rawArguments = raw
        return preset
    }

    @Test func codexArgumentGrammar() {
        for flag in ["--search", "--no-alt-screen", "--oss", "--strict-config", "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox", "--yolo"] {
            #expect(validation([flag], .codex) == nil, "\(flag)")
            #expect(validation([flag + "=1"], .codex) == "invalid", "\(flag)=")
        }
        for option in ["-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "--enable", "--disable", "--local-provider", "-i", "--image"] {
            #expect(validation([option, "value"], .codex) == nil, "\(option)")
            #expect(validation([option + "=value"], .codex) == nil, "\(option)=")
            #expect(validation([option], .codex) == "invalid", "\(option) without value")
            #expect(validation([option, "--search"], .codex) == "invalid", "\(option) followed by a flag")
        }
        for blocked in ["--", "--add-dir", "--worktree", "--resume", "--continue", "--session-id", "--fork-session", "--remote", "--remote-auth-token-env", "--cloud", "--teleport",
                        "-C", "--cd", "-c", "--config", "--last", "--all"] {
            #expect(validation([blocked, "x"], .codex) == "managed_argument", "\(blocked)")
            #expect(validation([blocked + "=x"], .codex) == "managed_argument", "\(blocked)=")
        }
        for conflict in ["-C/tmp", "-cfoo=bar"] { #expect(validation([conflict], .codex) == "managed_argument", "\(conflict)") }
        #expect(validation(["-c", "model_reasoning_effort=high"], .codex) == nil)
        #expect(validation(["--config", "model_reasoning_effort=high"], .codex) == nil)
        #expect(validation(["-c=model_reasoning_effort=high"], .codex) == nil)
        #expect(validation(["-c", "notify=[]"], .codex) == "managed_argument")
        for claudeOnly in ["--verbose", "--effort", "--permission-mode", "--dangerously-skip-permissions", "-r", "-w", "--settings"] {
            #expect(validation([claudeOnly, "x"], .codex) != nil, "\(claudeOnly)")
        }
        #expect(validation(["resume"], .codex) == "invalid")
        #expect(validation(["—model", "x"], .codex) == "invalid")
        #expect(validation(["--model", "a\nb"], .codex) == "invalid")
    }

    @Test func claudeArgumentGrammar() {
        for flag in ["--verbose", "--chrome", "--no-chrome", "--ide", "--disable-slash-commands", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"] {
            #expect(validation([flag], .claude) == nil, "\(flag)")
            #expect(validation([flag + "=1"], .claude) == "invalid", "\(flag)=")
        }
        for option in ["--model", "--effort", "--permission-mode", "--agent", "--agents", "--append-system-prompt", "--system-prompt", "--allowedTools", "--allowed-tools",
                       "--disallowedTools", "--disallowed-tools", "--tools", "--name", "-n", "--fallback-model"] {
            #expect(validation([option, "value"], .claude) == nil, "\(option)")
            #expect(validation([option + "=value"], .claude) == nil, "\(option)=")
            #expect(validation([option], .claude) == "invalid", "\(option) without value")
        }
        for blocked in ["--", "--add-dir", "--worktree", "--resume", "--continue", "--session-id", "--fork-session", "--remote", "--remote-auth-token-env", "--cloud", "--teleport",
                        "-c", "-r", "-w", "--mcp-config", "--strict-mcp-config", "--settings", "--setting-sources", "--safe-mode", "--no-session-persistence", "--print", "-p",
                        "--output-format", "--input-format", "--plugin-dir", "--plugin-url", "--environment", "--tmux"] {
            #expect(validation([blocked, "x"], .claude) == "managed_argument", "\(blocked)")
            #expect(validation([blocked + "=x"], .claude) == "managed_argument", "\(blocked)=")
        }
        for conflict in ["-r123", "-wtree"] { #expect(validation([conflict], .claude) == "managed_argument", "\(conflict)") }
        #expect(validation(["-c", "model_reasoning_effort=high"], .claude) == "managed_argument")
        for codexOnly in ["-m", "--sandbox", "--yolo", "--search", "-C"] {
            #expect(validation([codexOnly, "x"], .claude) != nil, "\(codexOnly)")
        }
        #expect(validation(["fix the bug"], .claude) == "invalid")
    }

    @Test func shellArgumentsOnlyRejectControlCharacters() {
        #expect(validation(["--add-dir", "-c", "anything", "resume"], .shell) == nil)
        #expect(validation(["a\0b"], .shell) == "invalid")
        #expect(validation(["a\nb"], .shell) == "invalid")
    }

    @Test func launchEnvironmentSelectsTheProviderProfile() throws {
        #expect(LaunchPolicy.deniedPrefixes == ["CODEX_", "CLAUDE_", "CLAUDECODE", "OPENCODE_", "OPENAI_", "ANTHROPIC_", "AZURE_OPENAI_", "CHAUFFEUR_", "AWS_", "GOOGLE_", "VERTEX_", "BEDROCK_"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-env-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ["PATH": "/bin", "CLAUDECODE": "1", "CODEX_THREAD_ID": "x", "TMUX": "x", "TERM": "dumb"]
        let sessionID = UUID()
        let codex = try LaunchPolicy.environment(base: base, preset: preset(.codex, raw: "", directory: root.path), projectID: UUID(), sessionID: sessionID, token: "t")
        #expect(Set(codex.keys) == ["PATH", "CODEX_HOME", "CHAUFFEUR_SESSION_ID", "CHAUFFEUR_SESSION_URL", "CHAUFFEUR_SESSION_TOKEN", "TERM", "COLORTERM"])
        #expect(codex["CODEX_HOME"] == Paths.canonical(root.path) && codex["CHAUFFEUR_SESSION_TOKEN"] == "t" && codex["TERM"] == "xterm-256color" && codex["COLORTERM"] == "truecolor")
        let claude = try LaunchPolicy.environment(base: base, preset: preset(.claude, raw: "", directory: root.path), projectID: UUID(), sessionID: sessionID, token: "t")
        #expect(Set(claude.keys) == ["PATH", "CLAUDE_CONFIG_DIR", "CHAUFFEUR_SESSION_ID", "CHAUFFEUR_SESSION_URL", "CHAUFFEUR_SESSION_TOKEN", "TERM", "COLORTERM"])
        #expect(claude["CLAUDE_CONFIG_DIR"] == Paths.canonical(root.path))

        // Team configuration only contributes the two profile selectors, and wins over the preset's own directory.
        let team = ["CODEX_HOME": "/team/codex", "CLAUDE_CONFIG_DIR": "/team/claude", "OTHER": "x"]
        let overridden = try LaunchPolicy.environment(base: base, preset: preset(.claude, raw: "", directory: root.path), projectID: UUID(), sessionID: sessionID, token: "t", configurationEnvironment: team)
        #expect(overridden["CLAUDE_CONFIG_DIR"] == "/team/claude" && overridden["CODEX_HOME"] == "/team/codex" && overridden["OTHER"] == nil)
        let shell = try LaunchPolicy.environment(base: base, preset: preset(.shell, raw: "", directory: root.path), projectID: UUID(), sessionID: sessionID, token: "t", configurationEnvironment: team)
        #expect(Set(shell.keys) == ["PATH", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CHAUFFEUR_SESSION_ID", "CHAUFFEUR_SESSION_URL", "TERM", "COLORTERM"])

        let missing = root.appendingPathComponent("missing").path
        #expect(code { _ = try LaunchPolicy.environment(base: base, preset: preset(.codex, raw: "", directory: missing), projectID: UUID(), sessionID: sessionID, token: "t") } == "missing_directory")
        let allowed = try LaunchPolicy.environment(base: base, preset: preset(.codex, raw: "", directory: missing), projectID: UUID(), sessionID: sessionID, token: "t", allowMissingConfiguration: true)
        #expect(allowed["CODEX_HOME"] == Paths.canonical(missing))

        #expect(SetupEnvironment.make(base: base, kind: .codex, directory: root.path) == ["PATH": "/bin", "CODEX_HOME": Paths.canonical(root.path), "TERM": "xterm-256color", "COLORTERM": "truecolor"])
        #expect(SetupEnvironment.make(base: base, kind: .claude, directory: root.path) == ["PATH": "/bin", "CLAUDE_CONFIG_DIR": Paths.canonical(root.path), "TERM": "xterm-256color", "COLORTERM": "truecolor"])
        #expect(SetupEnvironment.make(base: base, kind: .shell, directory: root.path) == ["PATH": "/bin", "TERM": "xterm-256color", "COLORTERM": "truecolor"])
    }

    @Test func onlyCodexReadOnlySandboxRejectsAdditionalFolders() {
        for arguments in [["--sandbox", "read-only"], ["-s", "read-only"], ["--sandbox=read-only"], ["-s=read-only"]] {
            var codex = preset(.codex, raw: ""); codex.arguments = arguments
            #expect(code { try LaunchPolicy.validateAdditionalDirectories(["/a"], preset: codex) } == "unsupported_directories", "\(arguments)")
            #expect(code { try LaunchPolicy.validateAdditionalDirectories([], preset: codex) } == nil)
            var claude = preset(.claude, raw: ""); claude.arguments = arguments
            #expect(code { try LaunchPolicy.validateAdditionalDirectories(["/a"], preset: claude) } == nil)
        }
        var writable = preset(.codex, raw: ""); writable.arguments = ["--sandbox", "workspace-write"]
        #expect(code { try LaunchPolicy.validateAdditionalDirectories(["/a"], preset: writable) } == nil)
    }

    @Test func providerIdentityAndProfileSelectors() {
        #expect(CLIKind.codex.displayName == "Codex" && CLIKind.claude.displayName == "Claude Code" && CLIKind.shell.displayName == "Shell")
        #expect(ShellAgentEnvironment.variableName(for: .codex) == "CODEX_HOME")
        #expect(ShellAgentEnvironment.variableName(for: .claude) == "CLAUDE_CONFIG_DIR")
        #expect(ShellAgentEnvironment.variableName(for: .shell) == nil)
        let team = PresetSet(name: "Fixture")
        #expect(team.configurationDirectory(for: .claude, home: "/Users/me") == "/Users/me/.claude")
        #expect(team.configurationDirectory(for: .codex, home: "/Users/me") == "/Users/me/.codex")
        #expect(Set(team.configurationEnvironment.keys) == ["CODEX_HOME", "CLAUDE_CONFIG_DIR"])
    }

    @Test func launchOptionSuggestions() {
        #expect(LaunchOptions.modelSuggestions(for: .codex) == ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
        #expect(LaunchOptions.modelSuggestions(for: .claude) == ["opus", "sonnet", "haiku"])
        #expect(LaunchOptions.modelSuggestions(for: .shell).isEmpty)
        #expect(LaunchOptions.reasoningSuggestions(for: .codex) == ["low", "medium", "high", "xhigh"])
        #expect(LaunchOptions.reasoningSuggestions(for: .claude) == ["low", "medium", "high", "xhigh", "max"])
        #expect(LaunchOptions.reasoningSuggestions(for: .shell).isEmpty)
    }

    @Test func launchOptionRecognition() {
        for (raw, model) in [("-m a", "a"), ("-m=a", "a"), ("--model a", "a"), ("--model=a", "a")] {
            #expect(LaunchOptions.inspect(rawArguments: raw, kind: .codex).model == model, "\(raw)")
        }
        for raw in [#"-c model_reasoning_effort="high""#, "--config model_reasoning_effort='high'", "-c=model_reasoning_effort=high", "--config=model_reasoning_effort=high"] {
            let inspection = LaunchOptions.inspect(rawArguments: raw, kind: .codex)
            #expect(inspection.reasoning == "high" && inspection.warnings.isEmpty, "\(raw)")
        }
        #expect(LaunchOptions.inspect(rawArguments: "--effort high", kind: .codex).reasoning == nil)
        #expect(LaunchOptions.inspect(rawArguments: "--model a --effort=max", kind: .claude) == LaunchArgumentInspection(arguments: ["--model", "a", "--effort=max"], model: "a", reasoning: "max", warnings: []))
        let claudeShort = LaunchOptions.inspect(rawArguments: "-m a", kind: .claude)
        #expect(claudeShort.model == nil && claudeShort.warnings == ["Unsupported launch argument -m. Use the dedicated launch fields or a supported native option"])
        #expect(LaunchOptions.inspect(rawArguments: "--model a --effort high", kind: .shell) == LaunchArgumentInspection(arguments: ["--model", "a", "--effort", "high"], model: nil, reasoning: nil, warnings: []))
        let missing = LaunchOptions.inspect(rawArguments: "--effort", kind: .claude)
        #expect(missing.reasoning == nil && missing.warnings == ["--effort is missing its value", "--effort requires an explicit value"])
        let conflict = LaunchOptions.inspect(rawArguments: "-c model_reasoning_effort=low -c=model_reasoning_effort=high", kind: .codex)
        #expect(conflict.reasoning == nil && conflict.warnings == ["Launch arguments contain conflicting reasoning values: low, high"])
    }

    @Test func launchOptionRewriting() throws {
        func edit(_ field: LaunchOptionField, _ value: String?, _ raw: String, _ kind: CLIKind) throws -> [String] {
            try ArgumentText.parse(LaunchOptions.updating(field: field, value: value, rawArguments: raw, kind: kind))
        }
        #expect(try edit(.model, "b", "-m a --search -m=c --model=d", .codex) == ["--search", "--model", "b"])
        #expect(try edit(.reasoning, "low", "-c=model_reasoning_effort=high -c foo=1 --config model_reasoning_effort=x", .codex) == ["-c", "foo=1", "-c", "model_reasoning_effort=low"])
        #expect(try edit(.reasoning, "", "-c model_reasoning_effort=high", .codex) == [])
        #expect(try edit(.reasoning, "max", "--effort low --effort=high --verbose", .claude) == ["--verbose", "--effort", "max"])
        #expect(try edit(.model, "b", "-m a", .claude) == ["-m", "a", "--model", "b"])
        #expect(try edit(.model, "b", "--model a", .shell) == ["--model", "a"])
    }

    @Test func launchOptionResolution() throws {
        let codex = try LaunchOptions.resolve(preset: preset(.codex, raw: "-m a -c model_reasoning_effort=low --search"), modelOverride: "b", reasoningOverride: "high")
        #expect(codex == ResolvedLaunchOptions(arguments: ["--search", "--model", "b", "-c", "model_reasoning_effort=high"], model: "b", reasoning: "high", executionPolicy: .standard))
        let cleared = try LaunchOptions.resolve(preset: preset(.claude, raw: "--model a --effort low"), modelOverride: "", reasoningOverride: "")
        #expect(cleared == ResolvedLaunchOptions(arguments: [], model: nil, reasoning: nil, executionPolicy: .standard))
        #expect(code { _ = try LaunchOptions.resolve(preset: preset(.codex, raw: "-c model_reasoning_effort=low -c model_reasoning_effort=high")) } == "conflicting_launch_option")
        #expect(code { _ = try LaunchOptions.resolve(preset: preset(.claude, raw: "--resume x")) } == "managed_argument")

        let delegatedCodex = try LaunchOptions.resolve(preset: preset(.codex, raw: "--sandbox=read-only -a never -s workspace-write --yolo --ask-for-approval=untrusted --search"), delegated: true)
        #expect(delegatedCodex.arguments == ["--search", "--dangerously-bypass-approvals-and-sandbox"] && delegatedCodex.executionPolicy == .delegatedYOLO)
        let alreadyCodex = try LaunchOptions.resolve(preset: preset(.codex, raw: "--dangerously-bypass-approvals-and-sandbox --model a"), delegated: true)
        #expect(alreadyCodex.arguments == ["--model", "a", "--dangerously-bypass-approvals-and-sandbox"])
        let delegatedClaude = try LaunchOptions.resolve(preset: preset(.claude, raw: "--dangerously-skip-permissions --permission-mode=plan --verbose --permission-mode default"), delegated: true)
        #expect(delegatedClaude.arguments == ["--verbose", "--dangerously-skip-permissions"] && delegatedClaude.executionPolicy == .delegatedYOLO)
        let delegatedShell = try LaunchOptions.resolve(preset: preset(.shell, raw: "-l"), delegated: true)
        #expect(delegatedShell == ResolvedLaunchOptions(arguments: ["-l"], model: nil, reasoning: nil, executionPolicy: .delegatedYOLO))
    }

    @Test func nativeConversationRules() {
        #expect(NativeConversation.identityChangingSources(.claude) == ["clear", "resume"])
        #expect(NativeConversation.identityChangingSources(.codex) == ["startup", "clear", "resume", "fork"])
        #expect(NativeConversation.identityChangingSources(.shell).isEmpty)
        #expect(NativeConversation.adoptsFirst(kind: .claude, hooksTrusted: true, hookEvent: nil))
        #expect(!NativeConversation.adoptsFirst(kind: .codex, hooksTrusted: true, hookEvent: nil))
        #expect(NativeConversation.adoptsFirst(kind: .shell, hooksTrusted: true, hookEvent: nil))
    }
}
