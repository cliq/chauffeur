import Foundation
import Testing
@testable import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct KimiIntegrationTests {
    @Test func sharedPluginDoesNotStoreSessionSecretsOrReplaceOtherPlugins() throws {
        let kind = try #require(CLIKind(rawValue: "kimi"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let registry = plugins.appendingPathComponent("installed.json")
        try Data(#"{"version":1,"plugins":[{"id":"existing","root":"/existing","enabled":true,"source":"local-path","installedAt":"2026-01-01"}]}"#.utf8).write(to: registry)
        let team = PresetSet(name: "Personal")
        let preset = AgentPreset(setID: team.id, name: "Kimi", kind: kind, executable: "kimi", configurationDirectory: root.path)
        let launch = LaunchSnapshot(preset: preset, set: team, executablePath: "/bin/kimi", executableVersion: "2.1.1", workingDirectory: root.path, additionalPaths: ["/tmp/extra"])
        var session = Session(projectID: UUID(), groupID: UUID(), title: "Kimi", launch: launch, folderID: UUID())
        session.nativeConversationID = "session_12345678-1234-1234-1234-123456789abc"
        for resume in [false, true] {
            let native = try CLIAdapter.launch(session: session, endpoint: "http://127.0.0.1:1234/mcp", ctlPath: "/tmp/chauffeurctl", integrationDirectory: root, coordination: true, resume: resume, preparation: LaunchPreparation())
            #expect(native.arguments == (resume ? ["--session", session.nativeConversationID!, "--add-dir", "/tmp/extra"] : ["--add-dir", "/tmp/extra"]))
        }
        let registered = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: registry))["plugins"].array
        #expect(registered.count == 2)
        #expect(registered.first?["id"].string == "existing")
        let record = try #require(registered.first { $0["id"].string == "chauffeur" })
        let manifest = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(record["root"].string)).appendingPathComponent("kimi.plugin.json")))
        #expect(manifest["mcpServers"]["chauffeur"]["command"].string == "sh")
        #expect(manifest["mcpServers"]["chauffeur"]["args"] == .array([.string("-c"), .string("exec '/tmp/chauffeurctl' kimi-mcp")]))
        #expect(manifest["hooks"].array.contains { $0["event"].string == "SessionStart" } == true)
        #expect(!String(decoding: try JSONCoding.encode(manifest), as: UTF8.self).contains(session.id.uuidString))
    }
    @Test func observationalToolHookDoesNotClaimInboxReminders() async throws {
        let manifest = KimiIntegration.manifest(ctlPath: "/bin/echo")
        let hooks = try #require(manifest["hooks"] as? [[String: Any]])
        let command = try #require(hooks.first { $0["event"] as? String == "PostToolUse" }?["command"] as? String)
        let result = try await ProcessRunner.run("/bin/sh", ["-c", command], environment: ["CHAUFFEUR_KIMI_TOKEN": "fixture", "CHAUFFEUR_CTL": "/bin/echo"])
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "event running")
        let stop = try #require(hooks.first { $0["event"] as? String == "Stop" }?["command"] as? String)
        let completed = try await ProcessRunner.run("/bin/sh", ["-c", stop], environment: ["CHAUFFEUR_KIMI_TOKEN": "fixture", "CHAUFFEUR_CTL": "/bin/echo"])
        #expect(completed.output.trimmingCharacters(in: .whitespacesAndNewlines) == "event turn-finished")
        let ordinary = try await ProcessRunner.run("/bin/sh", ["-c", command], environment: ["CHAUFFEUR_CTL": "/bin/echo"])
        #expect(ordinary.output.isEmpty)
    }

}
