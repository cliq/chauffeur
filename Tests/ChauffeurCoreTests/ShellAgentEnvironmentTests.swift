import ChauffeurCore
import Foundation
import Testing

struct ShellAgentEnvironmentTests {
    private func preset(_ name: String, kind: CLIKind, set: PresetSet, directory: String, archived: Bool = false) -> AgentPreset {
        var preset = AgentPreset(setID: set.id, name: name, kind: kind, executable: "/usr/local/bin/\(kind.rawValue)", configurationDirectory: directory)
        preset.archived = archived
        return preset
    }

    @Test func exportsOneDirectoryPerAgentKindPreferringTheSetDefault() {
        var set = PresetSet(name: "Team")
        let claudeA = preset("Alpha", kind: .claude, set: set, directory: "/cfg/claude-a")
        let claudeB = preset("Beta", kind: .claude, set: set, directory: "/cfg/claude-b")
        let codex = preset("Codex", kind: .codex, set: set, directory: "/cfg/codex")
        let archived = preset("Old", kind: .codex, set: set, directory: "/cfg/old", archived: true)
        set.defaultPresetID = claudeB.id
        let other = PresetSet(name: "Other")
        let foreign = preset("Foreign", kind: .claude, set: other, directory: "/cfg/foreign")

        let variables = ShellAgentEnvironment.variables(presets: [claudeA, claudeB, codex, archived, foreign], set: set)
        #expect(variables == ["CLAUDE_CONFIG_DIR": "/cfg/claude-b", "CODEX_HOME": "/cfg/codex"])
    }

    @Test func fallsBackToTheFirstPresetByNameAndSkipsArchivedSets() {
        var set = PresetSet(name: "Team")
        let second = preset("Zeta", kind: .codex, set: set, directory: "/cfg/z")
        let first = preset("alpha", kind: .codex, set: set, directory: "/cfg/a")
        #expect(ShellAgentEnvironment.variables(presets: [second, first], set: set) == ["CODEX_HOME": "/cfg/a"])
        set.archived = true
        #expect(ShellAgentEnvironment.variables(presets: [second, first], set: set).isEmpty)
    }

    @Test func exportCommandIsSortedQuotedAndNilWhenEmpty() {
        let command = ShellAgentEnvironment.exportCommand(["CODEX_HOME": "/Users/me/My Codex", "CLAUDE_CONFIG_DIR": "/Users/me/it's"])
        #expect(command == "export CLAUDE_CONFIG_DIR='/Users/me/it'\\''s' CODEX_HOME='/Users/me/My Codex'")
        #expect(ShellAgentEnvironment.exportCommand([:]) == nil)
    }

    @Test func execPayloadDecodesWithoutAPreamble() throws {
        let legacy = Data(#"{"executable":"/bin/zsh","arguments":["-l"],"environment":{},"directory":"/tmp"}"#.utf8)
        let payload = try JSONCoding.decode(ExecPayload.self, from: legacy)
        #expect(payload.preamble == nil)
        let withPreamble = ExecPayload(executable: "/bin/zsh", arguments: [], environment: [:], directory: "/tmp", preamble: "export A='1'")
        let round = try JSONCoding.decode(ExecPayload.self, from: JSONCoding.encode(withPreamble))
        #expect(round.preamble == "export A='1'")
    }
}
