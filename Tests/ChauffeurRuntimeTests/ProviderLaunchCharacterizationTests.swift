import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// Pins the exact Claude and Codex launch contract: argv, per-launch files and
/// probe results. Changes here change what the native CLIs receive.
struct ProviderLaunchCharacterizationTests {
    private let ctl = "/x/chauffeurctl"
    private let endpoint = "http://127.0.0.1:1/mcp"

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-characterization-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func session(_ kind: CLIKind, root: URL, raw: String? = nil, resolved: [String]? = nil, additional: [String] = [], task: String? = nil, native: String? = nil, version: String = "fixture") -> Session {
        let set = PresetSet(name: "Fixture")
        var preset = AgentPreset(setID: set.id, name: "Fixture", kind: kind, executable: "/bin/false", configurationDirectory: root.path)
        preset.rawArguments = raw
        var launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/false", executableVersion: version, workingDirectory: root.path, additionalPaths: additional)
        launch.resolvedArguments = resolved
        var value = Session(projectID: UUID(), groupID: UUID(), title: "Fixture", launch: launch, folderID: UUID())
        value.initialTask = task; value.nativeConversationID = native
        return value
    }
    private func json(_ url: URL) throws -> JSONValue { try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: url)) }
    private func errorCode(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let error as ChauffeurError { return error.code } catch { return "unexpected" }
    }

    @Test func codexNewSessionArguments() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(.codex, root: root, raw: "--model gpt-x -c model_reasoning_effort=high", additional: ["/a", "/b"], task: "Fix it")
        let basic = try CLIAdapter.arguments(session: value, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: false, resume: false)
        #expect(basic == ["--model", "gpt-x", "-c", "model_reasoning_effort=high", "-C", root.path, "--add-dir", "/a", "--add-dir", "/b", "--", "Fix it"])

        let coordinated = try CLIAdapter.arguments(session: value, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: true, resume: false)
        #expect(coordinated == ["--model", "gpt-x", "-c", "model_reasoning_effort=high", "-C", root.path, "--add-dir", "/a", "--add-dir", "/b",
                                "-c", #"mcp_servers.chauffeur.url="http://127.0.0.1:1/mcp""#,
                                "-c", #"mcp_servers.chauffeur.bearer_token_env_var="CHAUFFEUR_SESSION_TOKEN""#,
                                "-c", "mcp_servers.chauffeur.tool_timeout_sec=360",
                                "-c", #"notify=["/x/chauffeurctl","event","--session","\#(value.id.uuidString)","turn-finished"]"#,
                                "--", "Fix it"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "Codex writes no launch files")

        let trust = ["/<session-flags>/config.toml:stop:0:0": "sha256:abc"]
        let trusted = try CLIAdapter.arguments(session: value, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: true, resume: false, codexHookTrust: trust)
        let inbox = #""'/x/chauffeurctl' 'inbox-hook' '--provider' 'codex' '--report-running'""#
        let hooks = ["-c", #"hooks.SessionStart=[{hooks=[{type="command",command="'/x/chauffeurctl' 'event' 'session-start'",timeout=5}]}]"#]
            + ["UserPromptSubmit", "PostToolUse", "Stop"].flatMap { ["-c", "hooks.\($0)=[{hooks=[{type=\"command\",command=\(inbox),timeout=5}]}]"] }
            + ["-c", #"hooks.state={"/<session-flags>/config.toml:stop:0:0"={trusted_hash="sha256:abc"}}"#]
        #expect(trusted == Array(coordinated.dropLast(2)) + hooks + ["--", "Fix it"])

        // A snapshot's resolved arguments win over the preset text; an empty task adds nothing.
        let snapshot = session(.codex, root: root, raw: "--model ignored", resolved: ["--model", "kept"], task: "")
        #expect(try CLIAdapter.arguments(session: snapshot, endpoint: "", ctlPath: ctl, integrationDirectory: root, coordination: false, resume: false) == ["--model", "kept", "-C", root.path])
    }

    @Test func codexResumeArguments() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let value = session(.codex, root: root, additional: ["/a"], task: "ignored on resume", native: id)
        #expect(try CLIAdapter.arguments(session: value, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: false, resume: true)
                == ["-C", root.path, "--add-dir", "/a", "resume", id])
        let coordinated = try CLIAdapter.arguments(session: value, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: true, resume: true)
        #expect(coordinated.suffix(2) == ["resume", id] && coordinated.contains("mcp_servers.chauffeur.tool_timeout_sec=360"))
        for native in [nil, "not-a-uuid", "ses_abc123"] {
            let invalid = session(.codex, root: root, native: native)
            #expect(errorCode { _ = try CLIAdapter.arguments(session: invalid, endpoint: "", ctlPath: ctl, integrationDirectory: root, coordination: false, resume: true) } == "resume_unavailable")
        }
    }

    @Test func claudeNewSessionArgumentsAndLaunchFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let value = session(.claude, root: root, raw: "--model opus --effort high", additional: ["/a", "/b"], task: "Fix it")
        let basic = try CLIAdapter.arguments(session: value, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: false, resume: false)
        #expect(basic == ["--model", "opus", "--effort", "high", "--session-id", value.id.uuidString, "--add-dir", "/a", "--add-dir", "/b", "--", "Fix it"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty, "Basic mode writes no launch files")

        let native = UUID().uuidString
        var preassigned = value; preassigned.nativeConversationID = native
        let mcp = root.appendingPathComponent("mcp.json"), settings = root.appendingPathComponent("settings.json")
        let coordinated = try CLIAdapter.arguments(session: preassigned, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: true, resume: false)
        #expect(coordinated == ["--model", "opus", "--effort", "high", "--session-id", native, "--add-dir", "/a", "--add-dir", "/b",
                                "--mcp-config", mcp.path, "--settings", settings.path, "--", "Fix it"])
        #expect(try json(mcp) == .object(["mcpServers": .object(["chauffeur": .object([
            "type": .string("http"), "url": .string(endpoint), "timeout": .number(360_000),
            "headers": .object(["Authorization": .string("Bearer ${CHAUFFEUR_SESSION_TOKEN}")])])])]))

        func group(_ command: String, matcher: String? = nil) -> JSONValue {
            var value: [String: JSONValue] = ["hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .number(5)])])]
            if let matcher { value["matcher"] = .string(matcher) }
            return .object(value)
        }
        func status(_ event: String) -> String { "'/x/chauffeurctl' 'event' '--session' '\(value.id.uuidString)' '\(event)'" }
        let inbox = "'/x/chauffeurctl' 'inbox-hook' '--provider' 'claude'"
        let expected: JSONValue = .object([
            "hooks": .object([
                "SessionStart": .array([group(status("running"))]),
                "UserPromptSubmit": .array([group(status("running")), group(inbox)]),
                "PostToolUse": .array([group(status("running")), group(inbox)]),
                "PostToolUseFailure": .array([group(status("running"))]),
                "StopFailure": .array([group(status("needs-attention"))]),
                "Notification": .array([group(status("needs-attention"), matcher: "^(permission_prompt|elicitation_dialog|elicitation_url_dialog)$")]),
                "PermissionRequest": .array([group(status("needs-attention"))]),
                "Stop": .array([group(inbox + " '--report-stop'")])
            ]),
            "permissions": .object(["allow": .array([.string("Bash(/x/chauffeurctl wait-for-work:*)")])])
        ])
        #expect(try json(settings) == expected)

        // Delegated sessions of a recognized Claude build also turn off prompt suggestions.
        var delegated = session(.claude, root: root, version: "2.1.278 (Claude Code)")
        delegated.delegationID = UUID()
        _ = try CLIAdapter.arguments(session: delegated, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: true, resume: false)
        #expect(try json(settings)["promptSuggestionEnabled"] == .bool(false))
        delegated.launch.executableVersion = "not claude"
        _ = try CLIAdapter.arguments(session: delegated, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: true, resume: false)
        #expect(try json(settings)["promptSuggestionEnabled"] == .null)
    }

    @Test func claudeResumeArguments() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let value = session(.claude, root: root, raw: "--verbose", additional: ["/a"], task: "ignored on resume", native: id)
        #expect(try CLIAdapter.arguments(session: value, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: false, resume: true)
                == ["--verbose", "--resume", id, "--add-dir", "/a"])
        #expect(try CLIAdapter.arguments(session: value, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: true, resume: true)
                == ["--verbose", "--resume", id, "--add-dir", "/a", "--mcp-config", root.appendingPathComponent("mcp.json").path, "--settings", root.appendingPathComponent("settings.json").path])
        for native in [nil, "not-a-uuid", "ses_abc123"] {
            let invalid = session(.claude, root: root, native: native)
            #expect(errorCode { _ = try CLIAdapter.arguments(session: invalid, endpoint: "", ctlPath: ctl, integrationDirectory: root, coordination: false, resume: true) } == "resume_unavailable")
        }
    }

    @Test func shellAndInvalidArguments() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let shell = session(.shell, root: root, raw: "-l", task: "ignored")
        #expect(try CLIAdapter.arguments(session: shell, endpoint: endpoint, ctlPath: ctl, integrationDirectory: root, coordination: true, resume: false) == ["-l"])
        #expect(errorCode { _ = try CLIAdapter.arguments(session: shell, endpoint: "", ctlPath: ctl, integrationDirectory: root, coordination: false, resume: true) } == "resume_unavailable")
        for kind in [CLIKind.codex, .claude] {
            let managed = session(kind, root: root, resolved: ["--add-dir", "/x"])
            #expect(errorCode { _ = try CLIAdapter.arguments(session: managed, endpoint: "", ctlPath: ctl, integrationDirectory: root, coordination: false, resume: false) } == "managed_argument")
        }
    }

    @Test func providerIdentificationAndCapabilityFlags() async throws {
        #expect(CLIAdapter.identifiesProvider(kind: .codex, version: "codex-cli 0.1"))
        #expect(!CLIAdapter.identifiesProvider(kind: .codex, version: "codex 0.1"))
        #expect(CLIAdapter.identifiesProvider(kind: .claude, version: "2.1.0 (Claude Code)"))
        #expect(!CLIAdapter.identifiesProvider(kind: .claude, version: "Claude Code 2.1.0"))
        #expect(!CLIAdapter.identifiesProvider(kind: .shell, version: "codex-cli 0.1"))

        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        func cli(_ version: String, _ help: String) throws -> String {
            let path = root.appendingPathComponent("cli-\(UUID().uuidString.prefix(8))").path
            try "#!/bin/sh\ncase \"$1\" in --version) echo '\(version)';; --help) echo '\(help)';; *) exit 1;; esac\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            return path
        }
        let environment = ["PATH": "/usr/bin:/bin"]
        let codex = try await CLIAdapter.capabilities(executable: cli("codex-cli 0.155.1", "--dangerously-skip-permissions"), kind: .codex, environment: environment)
        #expect(codex.version == "codex-cli 0.155.1" && codex.coordination && codex.statusSignals)
        #expect(!codex.additionalDirectories && !codex.resume && !codex.delegatedYOLO, "Each provider probes only its own flag")
        #expect(codex.limitation == "Turn completion via notify; approval/input detection is unavailable")
        let claude = try await CLIAdapter.capabilities(executable: cli("2.1.278 (Claude Code)", "--dangerously-bypass-approvals-and-sandbox --add-dir resume"), kind: .claude, environment: environment)
        #expect(claude.coordination && claude.additionalDirectories && claude.resume && !claude.delegatedYOLO && claude.limitation == nil)
        let wrong = try await CLIAdapter.capabilities(executable: cli("codex-cli 0.155.1", "--dangerously-skip-permissions"), kind: .claude, environment: environment)
        #expect(!wrong.coordination && !wrong.statusSignals && wrong.delegatedYOLO)
        #expect(wrong.limitation == "The executable does not identify itself as the selected agent. Check the preset executable, or use basic terminal mode")
    }

    @Test func onlyRecognizedCodexCoordinatorsGetTypedResultWakes() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let root = fixture.root
        #expect(await fixture.runtime.resultWakeApplies(session(.codex, root: root, version: "codex-cli 0.155.1")))
        #expect(!(await fixture.runtime.resultWakeApplies(session(.codex, root: root, version: "2.1.278 (Claude Code)"))))
        #expect(!(await fixture.runtime.resultWakeApplies(session(.claude, root: root, version: "2.1.278 (Claude Code)"))))
        #expect(!(await fixture.runtime.resultWakeApplies(session(.shell, root: root, version: "codex-cli 0.155.1"))))
        var basic = session(.codex, root: root, version: "codex-cli 0.155.1"); basic.launch.preset.integration = .unavailable
        #expect(!(await fixture.runtime.resultWakeApplies(basic)))
        var settings = RetentionSettings(); settings.wakeIdleCoordinators = false
        _ = try await fixture.runtime.handle(IPCRequest("saveSettings", params: try .from(settings)))
        #expect(!(await fixture.runtime.resultWakeApplies(session(.codex, root: root, version: "codex-cli 0.155.1"))))
    }

    @Test func composerReadinessTrimsAndIgnoresShells() {
        #expect(TmuxHost.composerReadiness(kind: .codex, activeLine: "  › Ask Codex to do anything  ") == .ready)
        #expect(TmuxHost.composerReadiness(kind: .codex, activeLine: "›") == .inputPending)
        #expect(TmuxHost.composerReadiness(kind: .codex, activeLine: "❯ ") == .unrecognized)
        #expect(TmuxHost.composerReadiness(kind: .claude, activeLine: "  ❯  ") == .ready)
        #expect(TmuxHost.composerReadiness(kind: .claude, activeLine: "› Ask Codex to do anything") == .unrecognized)
        #expect(TmuxHost.composerReadiness(kind: .shell, activeLine: "❯ ") == .unrecognized)
        #expect(TmuxHost.composerReadiness(kind: .shell, activeLine: "› Ask Codex to do anything") == .unrecognized)
        #expect(!TmuxHost.supportsFollowUp(kind: .codex, version: "2.1.278 (Claude Code)"))
        #expect(!TmuxHost.supportsFollowUp(kind: .claude, version: "codex-cli 0.155.1"))
    }
}
