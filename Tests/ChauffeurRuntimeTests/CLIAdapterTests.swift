import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct CLIAdapterTests {
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
}
