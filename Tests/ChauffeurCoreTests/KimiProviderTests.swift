import Foundation
import Testing
@testable import ChauffeurCore

struct KimiProviderTests {
    @Test func sharedHomeAndExplicitTeamOverride() throws {
        let kind = try #require(CLIKind(rawValue: "kimi"))
        var team = PresetSet(name: "Personal", agentSelection: .allBase)
        #expect(team.configurationDirectory(for: kind, home: "/tmp/person") == "/private/tmp/person/.kimi-code")
        team.configurationDirectories = ["kimi": "/tmp/team-kimi"]
        #expect(team.configurationDirectory(for: kind) == "/private/tmp/team-kimi")
        let env = SetupEnvironment.make(base: ["KIMI_CODE_HOME": "/other", "KIMI_MODEL_NAME": "other", "PATH": "/bin"], kind: kind, directory: "/tmp/team-kimi")
        #expect(env["KIMI_CODE_HOME"] == "/private/tmp/team-kimi")
        #expect(env["KIMI_MODEL_NAME"] == nil)
    }
    @Test func nativeSessionIdentitySurvivesHooks() throws {
        let kind = try #require(CLIKind(rawValue: "kimi"))
        let id = "session_12345678-1234-1234-1234-123456789abc"
        let payload = HookPayload.parse(Data("{\"session_id\":\"\(id)\",\"hook_event_name\":\"SessionStart\",\"source\":\"resume\"}".utf8))
        #expect(payload.conversationID == id)
        #expect(kind.provider?.validatesConversationID(id) == true)
        #expect(NativeConversation.same(id, id))
        #expect(NativeConversation.adopts(kind: kind, hookEvent: payload.hookEvent, source: payload.source))
    }
    @Test func managedFlagsCannotChangeLaunchMode() throws {
        let kind = try #require(CLIKind(rawValue: "kimi"))
        for args in [["--prompt", "task"], ["-Ssession_x"], ["--session=x"], ["--skills-dir", "/tmp"], ["-c"]] {
            #expect(throws: ChauffeurError.self) { try LaunchPolicy.validateArguments(args, kind: kind) }
        }
        try LaunchPolicy.validateArguments(["--model", "kimi-for-coding", "--auto"], kind: kind)
        #expect(kind.provider?.autoApprove.flag == "--auto")
    }
    @Test func composerRejectsDraftsAndDialogs() {
        let provider = KimiProvider()
        let lines = [" ╭────────────╮", " │ >          │", " ╰────────────╯"]
        #expect(provider.composerReadiness(screen: ComposerScreen(lines: lines, cursorX: 5, cursorY: 1)) == .ready)
        var draft = lines; draft[1] = " │ > work     │"
        #expect(provider.composerReadiness(screen: ComposerScreen(lines: draft, cursorX: 9, cursorY: 1)) == .inputPending)
        #expect(provider.composerReadiness(screen: ComposerScreen(lines: ["Trust this folder?", "❯ Trust"], cursorX: 5, cursorY: 1)) == .unrecognized)
        #expect(provider.composerReadiness(activeLine: "│ > │") == .unrecognized)
    }
    @Test func kimiRemindersOnlyInjectAtPromptSubmission() throws {
        let summary = InboxHintSummary(count: 1, block: true)
        let output = try #require(InboxHintFormatter.kimiOutput(event: "UserPromptSubmit", summary: summary))
        #expect(String(decoding: output, as: UTF8.self).contains("chauffeur_inbox"))
        #expect(InboxHintFormatter.kimiOutput(event: "Stop", summary: summary) == nil)
        #expect(InboxHintFormatter.kimiOutput(event: "PostToolUse", summary: summary) == nil)
    }

}
