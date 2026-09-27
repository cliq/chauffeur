import Foundation
import Testing
@testable import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct PiIntegrationTests {
    @Test func launchKeepsPromptLiteralAndExtensionPerInvocation() throws {
        let kind = try #require(CLIKind(rawValue: "pi"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let team = PresetSet(name: "Personal")
        let preset = AgentPreset(setID: team.id, name: "Pi", kind: kind, executable: "pi", configurationDirectory: root.path)
        let launch = LaunchSnapshot(preset: preset, set: team, executablePath: "/bin/pi", executableVersion: "0.87.1", workingDirectory: root.path, additionalPaths: ["/tmp/extra"])
        var session = Session(projectID: UUID(), groupID: UUID(), title: "Pi", launch: launch, folderID: UUID())
        session.nativeConversationID = UUID().uuidString
        session.initialTask = "@this is a task, not a file"
        let native = try CLIAdapter.launch(session: session, endpoint: "http://127.0.0.1:1234/mcp", ctlPath: "/tmp/ctl", integrationDirectory: root, coordination: true, resume: false, preparation: LaunchPreparation(), pluginPath: "/tmp/chauffeur-pi.js")
        #expect(native.arguments.prefix(2) == ["--session-id", session.nativeConversationID!.lowercased()])
        #expect(native.arguments.contains("/tmp/chauffeur-pi.js"))
        #expect(native.arguments.suffix(2) == ["--", "\n@this is a task, not a file"])
        #expect(native.environment["CHAUFFEUR_PI_ENDPOINT"] == "http://127.0.0.1:1234/mcp")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
        let resumed = try CLIAdapter.launch(session: session, endpoint: "", ctlPath: "/tmp/ctl", integrationDirectory: root, coordination: false, resume: true, preparation: LaunchPreparation())
        #expect(resumed.arguments.prefix(2) == ["--session", session.nativeConversationID!.lowercased()])
        #expect(!resumed.arguments.contains("--extension"))
        #expect(!resumed.arguments.contains("--"))
        #expect(resumed.environment.isEmpty)
    }
}
