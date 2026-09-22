import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct CLIAdapterTests {
    /// A stand-in CLI that answers `--version` and `--help` like the real tools.
    private func fakeCLI(reporting version: String, help: String = "resume --add-dir", in root: URL) throws -> String {
        let path = root.appendingPathComponent("cli-\(UUID().uuidString.prefix(8))").path
        let script = "#!/bin/sh\ncase \"$1\" in --version) echo '\(version)';; --help) echo '\(help)';; *) exit 1;; esac\n"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }

    @Test func delegatedPolicyCapabilityComesFromNativeHelp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-cli-policy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["PATH": "/usr/bin:/bin"]
        let codex = try await CLIAdapter.capabilities(executable: fakeCLI(reporting: "codex-cli 0.154.0", help: "resume --add-dir --dangerously-bypass-approvals-and-sandbox", in: root), kind: .codex, environment: environment)
        let claude = try await CLIAdapter.capabilities(executable: fakeCLI(reporting: "2.1.278 (Claude Code)", help: "resume --add-dir --dangerously-skip-permissions", in: root), kind: .claude, environment: environment)
        #expect(codex.delegatedYOLO)
        #expect(claude.delegatedYOLO)
    }

    @Test func anyClaudeCodeBuildIsACoordinationCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-cli-versions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["PATH": "/usr/bin:/bin"]
        // Claude Code updates daily; a build newer than any we have inspected must still be usable.
        let claude = try await CLIAdapter.capabilities(executable: fakeCLI(reporting: "9.9.999 (Claude Code)", in: root), kind: .claude, environment: environment)
        #expect(claude.coordination && claude.statusSignals && claude.version == "9.9.999 (Claude Code)")
        #expect(claude.additionalDirectories && claude.resume)
        // Something that is not Claude Code at all is still rejected for coordination.
        let other = try await CLIAdapter.capabilities(executable: fakeCLI(reporting: "some-other-tool 1.0", in: root), kind: .claude, environment: environment)
        #expect(!other.coordination && other.limitation != nil)
        // Codex keeps its verified baseline.
        let codex = try await CLIAdapter.capabilities(executable: fakeCLI(reporting: "codex-cli 0.154.0", in: root), kind: .codex, environment: environment)
        let currentCodex = try await CLIAdapter.capabilities(executable: fakeCLI(reporting: "codex-cli 0.155.1", in: root), kind: .codex, environment: environment)
        let newerCodex = try await CLIAdapter.capabilities(executable: fakeCLI(reporting: "codex-cli 0.155.0", in: root), kind: .codex, environment: environment)
        #expect(codex.coordination && currentCodex.coordination && !newerCodex.coordination)
    }

    @Test func claudeAttentionNotificationsRequireUserInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-hook-filter-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let set = PresetSet(name: "Fixture")
        let preset = AgentPreset(setID: set.id, name: "Fixture", kind: .claude, executable: "/bin/false", configurationDirectory: root.path)
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/false", executableVersion: "fixture", workingDirectory: root.path, additionalPaths: [])
        let session = Session(projectID: UUID(), groupID: UUID(), title: "Fixture", launch: launch, folderID: UUID())
        _ = try CLIAdapter.arguments(session: session, endpoint: "http://127.0.0.1:1/mcp", ctlPath: "/bin/false", integrationDirectory: root, coordination: true, resume: false)
        let settings = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
        let groups = settings["hooks"]["Notification"].array
        #expect(!groups.isEmpty)
        func matches(_ type: String) throws -> Bool {
            try groups.contains { group in
                guard let matcher = group["matcher"].string else { return true }
                let pattern = try NSRegularExpression(pattern: matcher)
                return pattern.firstMatch(in: type, range: NSRange(type.startIndex..., in: type)) != nil
            }
        }
        for type in ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog"] {
            #expect(try matches(type), "A native input request must reach attention")
        }
        for type in ["idle_prompt", "auth_success", "agent_completed", "elicitation_complete", "elicitation_response", "quota_auto_resume_fired", "future_unknown_notification", "permission_prompt_resolved"] {
            #expect(try !matches(type), "Informational or unknown notifications must not fabricate blocked input")
        }
    }

    @Test func delegatedClaudeDisablesGhostPromptSuggestionsInLaunchSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-claude-suggestions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let set = PresetSet(name: "Fixture")
        let preset = AgentPreset(setID: set.id, name: "Fixture", kind: .claude, executable: "/bin/false", configurationDirectory: root.path)
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/false", executableVersion: "2.1.278 (Claude Code)", workingDirectory: root.path, additionalPaths: [])
        var delegated = Session(projectID: UUID(), groupID: UUID(), title: "Delegated", launch: launch, folderID: UUID())
        delegated.delegationID = UUID()
        _ = try CLIAdapter.arguments(session: delegated, endpoint: "http://127.0.0.1:1/mcp", ctlPath: "/bin/false", integrationDirectory: root, coordination: true, resume: false)
        var settings = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
        #expect(settings["promptSuggestionEnabled"].bool == false)

        delegated.launch.executableVersion = "2.1.279 (Claude Code)"
        _ = try CLIAdapter.arguments(session: delegated, endpoint: "http://127.0.0.1:1/mcp", ctlPath: "/bin/false", integrationDirectory: root, coordination: true, resume: false)
        settings = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
        #expect(settings["promptSuggestionEnabled"].bool == nil)

        let ordinary = Session(projectID: UUID(), groupID: UUID(), title: "Ordinary", launch: launch, folderID: UUID())
        _ = try CLIAdapter.arguments(session: ordinary, endpoint: "http://127.0.0.1:1/mcp", ctlPath: "/bin/false", integrationDirectory: root, coordination: true, resume: false)
        settings = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("settings.json")))
        #expect(settings["promptSuggestionEnabled"].bool == nil)
    }
}
