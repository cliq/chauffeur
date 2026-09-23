import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct FollowUpComposerTests {
    @Test func recognizesOnlyEmptyKnownProviderComposers() {
        #expect(TmuxHost.composerReadiness(kind: .codex, activeLine: "› Ask Codex to do anything") == .ready)
        #expect(TmuxHost.composerReadiness(kind: .codex, activeLine: "› existing draft") == .inputPending)
        #expect(TmuxHost.composerReadiness(kind: .codex, activeLine: "› 1. Allow") == .inputPending)
        #expect(TmuxHost.composerReadiness(kind: .codex, activeLine: "Working (3s)") == .unrecognized)

        #expect(TmuxHost.composerReadiness(kind: .claude, activeLine: "❯\u{00a0}") == .ready)
        #expect(TmuxHost.composerReadiness(kind: .claude, activeLine: "❯\u{00a0}existing draft") == .inputPending)
        #expect(TmuxHost.composerReadiness(kind: .claude, activeLine: "❯ Try \"write a test\"") == .inputPending)
        #expect(TmuxHost.composerReadiness(kind: .claude, activeLine: "❯ existing draft") == .inputPending)
        #expect(TmuxHost.composerReadiness(kind: .claude, activeLine: "❯ 1. Yes") == .inputPending)
        #expect(TmuxHost.composerReadiness(kind: .claude, activeLine: "esc to interrupt") == .unrecognized)
    }

    @Test func supportUsesProviderIdentityAcrossUpdates() {
        #expect(TmuxHost.supportsFollowUp(kind: .codex, version: "codex-cli 0.155.1"))
        #expect(TmuxHost.supportsFollowUp(kind: .claude, version: "2.1.278 (Claude Code)"))
        #expect(TmuxHost.supportsFollowUp(kind: .codex, version: "codex-cli 9.999.0"))
        #expect(TmuxHost.supportsFollowUp(kind: .claude, version: "9.999.0 (Claude Code)"))
        #expect(!TmuxHost.supportsFollowUp(kind: .shell, version: "zsh"))
    }
}

struct FollowUpSubmissionTests {
    @Test func submitsWhileTheUserIsScrolledBackInCopyMode() async throws {
        for provider in FollowUpFixture.Provider.allCases {
            let fixture = try await FollowUpFixture.make(provider: provider)
            defer { fixture.cleanup() }
            try await fixture.waitForScreen(provider.marker)
            // Scrolling the app's terminal puts the tmux pane into copy mode.
            try await fixture.tmuxCommand(["copy-mode", "-t", fixture.session.id.uuidString])
            try await fixture.submitWhenReady("while scrolled for \(provider.rawValue)")
            try await fixture.waitForLog("while scrolled for \(provider.rawValue)")
            #expect(try await fixture.tmuxCommand(["display-message", "-p", "-t", fixture.session.id.uuidString, "#{pane_in_mode}"]) == "1",
                    "Submitting leaves the user's scroll position alone")
        }
    }

    @Test func submitsInSameSessionAndRejectsDraftBusyAndUnsupported() async throws {
        for provider in FollowUpFixture.Provider.allCases {
            let fixture = try await FollowUpFixture.make(provider: provider)
            defer { fixture.cleanup() }
            let session = fixture.session
            try await fixture.waitForScreen(provider.marker)

            try await fixture.host.validateFollowUp(session: session)
            #expect(await fixture.errorCode {
                try await fixture.host.submitFollowUp(session: session, prompt: "unsafe\u{1b}[2J")
            } == "invalid")
            try await fixture.host.submitFollowUp(session: session, prompt: "correction for \(provider.rawValue)")
            try await fixture.waitForLog("correction for \(provider.rawValue)")
            try await fixture.waitForScreen(provider.marker)

            let generation = try await fixture.host.attach(sessionID: session.id, sink: RecordingSink(), cols: 100, rows: 30, takeControl: false)
            let second = Task { try await fixture.host.submitFollowUp(session: session, prompt: "serialized follow-up") }
            try await fixture.wait { await fixture.host.isFollowUpSubmissionPending(sessionID: session.id) }
            var inputCode: String?
            do { try await fixture.host.input(sessionID: session.id, generation: generation, bytes: Data("human draft".utf8)) }
            catch let error as ChauffeurError { inputCode = error.code }
            #expect(inputCode == "follow_up_submission_pending")
            try await second.value
            try await fixture.waitForLog("serialized follow-up")
            await fixture.host.detach(sessionID: session.id, generation: generation)

            try await fixture.sendLiteral("unsent draft")
            try await fixture.waitForScreen("unsent draft")
            let draftCode = await fixture.errorCode { try await fixture.host.validateFollowUp(session: session) }
            #expect(draftCode == "follow_up_input_pending", "\(provider.rawValue) received \(draftCode ?? "success")")
            try await fixture.sendKey("C-u")
            try await fixture.waitForScreen(provider.marker)

            var busy = session; busy.state = .running
            let busySession = busy
            #expect(await fixture.errorCode { try await fixture.host.validateFollowUp(session: busySession) } == "follow_up_busy")
            #expect(await fixture.errorCode {
                try await fixture.host.submitFollowUp(session: busySession, prompt: "line one\nline two\tindented")
            } == "follow_up_busy")
            var attention = session; attention.state = .needsAttention
            let attentionSession = attention
            #expect(await fixture.errorCode { try await fixture.host.validateFollowUp(session: attentionSession) } == "follow_up_needs_attention")
            var unsupported = session
            unsupported.launch.executableVersion = "some-other-tool 1.0"
            let unsupportedSession = unsupported
            #expect(await fixture.errorCode { try await fixture.host.validateFollowUp(session: unsupportedSession) } == "follow_up_unavailable")
        }
    }
}

private struct FollowUpFixture: Sendable {
    enum Provider: String, CaseIterable, Sendable {
        case codex, claude
        var kind: CLIKind { self == .codex ? .codex : .claude }
        var version: String { self == .codex ? "codex-cli 9.999.0" : "9.999.0 (Claude Code)" }
        var marker: String { self == .codex ? "› Ask Codex to do anything" : "❯\u{00a0}" }
    }

    let root: URL
    let host: TmuxHost
    let tmux: String
    let socket: String
    let session: Session
    let received: URL

    static func make(provider: Provider) async throws -> Self {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-follow-up-\(UUID())").resolvingSymlinksInPath()
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("helper.py")
        let agent = root.appendingPathComponent("agent.py")
        let received = root.appendingPathComponent("received.txt")
        try Data(#"""
        #!/usr/bin/python3
        import json, os, sys
        path = sys.argv[2]
        payload = json.loads(open(path).read())
        os.unlink(path)
        os.chdir(payload['directory'])
        os.execve(payload['executable'], [payload['executable'], *payload['arguments']], payload['environment'])
        """#.utf8).write(to: helper)
        try Data(#"""
        #!/usr/bin/python3
        import sys
        marker, received = sys.argv[1], sys.argv[2]
        print(marker, end='', flush=True)
        for line in sys.stdin:
            with open(received, 'a') as output: output.write(line)
            print('accepted:' + line.rstrip('\n'), flush=True)
            print(marker, end='', flush=True)
        """#.utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": root.path, "LANG": "en_US.UTF-8"]
        let tmux = try Paths.executable("tmux", environment: environment)
        let host = try TmuxHost(runtimeDirectory: runtime, ctlPath: helper.path, environment: environment)
        let set = PresetSet(name: "Follow-up fixture")
        let preset = AgentPreset(setID: set.id, name: provider.rawValue, kind: provider.kind, executable: agent.path, configurationDirectory: root.path)
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: agent.path, executableVersion: provider.version, workingDirectory: root.path, additionalPaths: [])
        var session = Session(projectID: UUID(), groupID: UUID(), title: "Follow-up", launch: launch, folderID: UUID())
        session.state = .turnFinished
        let pane = try await host.spawn(session: session, payload: ExecPayload(executable: agent.path, arguments: [provider.marker, received.path], environment: environment, directory: root.path), scrollback: 1_000)
        session.processID = pane.processID
        session.terminalIdentity = pane.paneID
        return Self(root: root, host: host, tmux: tmux, socket: runtime.appendingPathComponent("tmux.sock").path, session: session, received: received)
    }

    func wait(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0..<250 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ChauffeurError("fixture_timeout", "Follow-up fixture did not reach its checkpoint")
    }

    func waitForScreen(_ value: String) async throws {
        try await wait { try await host.capture(sessionID: session.id, lines: 100).screen.contains(value) }
    }

    func waitForLog(_ value: String) async throws {
        try await wait { (try? String(contentsOf: received, encoding: .utf8).contains(value)) == true }
    }

    func sendLiteral(_ text: String) async throws {
        let result = try await ProcessRunner.run(tmux, ["-S", socket, "send-keys", "-t", session.id.uuidString, "-l", "--", text])
        try #require(result.status == 0)
    }

    @discardableResult
    func tmuxCommand(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run(tmux, ["-S", socket] + arguments)
        try #require(result.status == 0)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func submitWhenReady(_ prompt: String) async throws { try await host.submitFollowUp(session: session, prompt: prompt) }

    func sendKey(_ key: String) async throws {
        let result = try await ProcessRunner.run(tmux, ["-S", socket, "send-keys", "-t", session.id.uuidString, key])
        try #require(result.status == 0)
    }

    func errorCode(_ operation: () async throws -> Void) async -> String? {
        do { try await operation(); return nil }
        catch let error as ChauffeurError { return error.code }
        catch { return "unexpected-error" }
    }

    func cleanup() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-S", socket, "kill-server"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run(); process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}
