import Foundation
import Testing
@testable import ChauffeurCore

struct PiProviderTests {
    @Test func composerRequiresEmptyBorderedEditorAndNativeFooter() throws {
        let provider = try #require(CLIKind(rawValue: "pi")?.provider)
        let lines = [String(repeating: "─", count: 80), "", String(repeating: "─", count: 80), "/tmp/project (main)", "0.0%/200k (auto)    model"]
        #expect(provider.composerReadiness(screen: ComposerScreen(lines: lines, cursorX: 0, cursorY: 1)) == .ready)
        var draft = lines; draft[1] = "my draft"
        #expect(provider.composerReadiness(screen: ComposerScreen(lines: draft, cursorX: 8, cursorY: 1)) == .inputPending)
        var busy = lines; busy[0] = "── working ──"
        #expect(provider.composerReadiness(screen: ComposerScreen(lines: busy, cursorX: 0, cursorY: 1)) == .unrecognized)
        #expect(provider.composerReadiness(screen: ComposerScreen(lines: ["Select a provider", "", "Cancel"], cursorX: 0, cursorY: 1)) == .unrecognized)
        #expect(provider.composerReadiness(screen: ComposerScreen(lines: lines, cursorX: 3, cursorY: 1)) == .inputPending)
    }
    @Test func teamHomeAndEnvironmentAreIsolated() throws {
        let kind = try #require(CLIKind(rawValue: "pi"))
        let team = PresetSet(name: "Personal", agentSelection: .allBase)
        #expect(team.configurationDirectory(for: kind, home: "/tmp/person") == "/private/tmp/person/.pi/agent")
        let env = SetupEnvironment.make(base: ["PI_CODING_AGENT_DIR": "/other", "PI_CODING_AGENT_SESSION_DIR": "/other/sessions", "PI_PACKAGE_DIR": "/other/package", "PATH": "/bin"], kind: kind, directory: "/tmp/team-pi")
        #expect(env["PI_CODING_AGENT_DIR"] == "/private/tmp/team-pi")
        #expect(env["PI_CODING_AGENT_SESSION_DIR"] == nil)
        #expect(env["PI_PACKAGE_DIR"] == nil)
        #expect(env["PATH"] == "/bin")
    }

    @Test func managedArgumentsProtectInteractiveSessionAndTools() throws {
        let kind = try #require(CLIKind(rawValue: "pi"))
        for args in [["--session", "x"], ["--session-id=x"], ["--mode", "rpc"], ["-p"], ["-r"], ["--extension", "x"], ["--no-tools"], ["--tools", "read"], ["--no-session"], ["--list-models"], ["--model=x"]] {
            #expect(throws: ChauffeurError.self) { try LaunchPolicy.validateArguments(args, kind: kind) }
        }
        try LaunchPolicy.validateArguments(["--model", "openai/gpt-5", "--thinking", "high", "--approve"], kind: kind)
        var preset = AgentPreset(setID: UUID(), name: "Pi", kind: kind, executable: "pi", configurationDirectory: "/tmp")
        preset.arguments = ["--no-approve"]
        let resolved = try LaunchOptions.resolve(preset: preset, modelOverride: "provider/model", reasoningOverride: "high", delegated: true)
        #expect(resolved.arguments == ["--model", "provider/model", "--thinking", "high", "--approve"])
    }

    @Test func identityRequiresPiHelpAndSupportsSessionSwitches() throws {
        let kind = try #require(CLIKind(rawValue: "pi"))
        let provider = try #require(kind.provider)
        #expect(!provider.identifies(version: "0.86.1"))
        #expect(provider.identifies(version: "0.87.0"))
        #expect(provider.identifies(version: "1.0.0"))
        #expect(!provider.identifies(version: "0.87.1", help: "some other CLI --session"))
        #expect(provider.identifies(version: "0.87.1", help: "pi - AI coding assistant\n--extension --session --session-id --thinking --approve"))
        #expect(provider.validatesConversationID(UUID().uuidString))
        #expect(!provider.validatesConversationID("partial-id"))
        #expect(NativeConversation.adopts(kind: kind, hookEvent: "SessionStart", source: "new"))
        #expect(provider.wakeStrategy == .plugin)
    }
}
