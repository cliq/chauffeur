import Foundation
import Testing
@testable import ChauffeurCore

struct DiagnosticsTests {
    private func session() -> Session {
        let set = PresetSet(name: "private-set-name")
        var preset = AgentPreset(setID: set.id, name: "private-preset-name", kind: .codex, executable: "/opt/bin/codex", configurationDirectory: "/Users/test/.codexwho-personal")
        preset.arguments = ["--model", "private-model-argument"]
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: preset.executable, executableVersion: "codex-cli 0.154.0", workingDirectory: "/Users/test/Project café", additionalPaths: [])
        var result = Session(projectID: UUID(), groupID: UUID(), title: "private-session-title", launch: launch, folderID: UUID())
        result.initialTask = "private-initial-task"; result.error = "sk-secret-from-provider-output"
        result.nativeConversationID = UUID().uuidString; result.launchRequestFingerprint = "private-request-fingerprint"
        result.failureCode = "missing_directory"; result.state = .failed
        return result
    }
    @Test func exportProjectsOnlyApprovedFieldsAndClampsUntrustedText() throws {
        var value = session()
        value.launch.additionalPaths = ["/tmp/sk-credential-value", "/tmp/ghp_credential", "/tmp/Bearer token", "/tmp/eyJhbGci.jwt.signature", "/tmp/config={\"token\":\"secret\"}", "/tmp/line\nsecret", "/tmp/" + String(repeating: "a", count: 50), "/tmp/normal"]
        let report = DiagnosticsReport(sessions: [value], health: .object(["version": .string("0.1.0-dev"), "status": .string("running")]),
            errors: [ChauffeurError("missing_directory", "private-error-message", path: "/Users/test/missing"), ChauffeurError("sk-secret-error-code", "private-error", path: "/tmp/token=private")], observation: .live, observedAt: Date())
        let json = try JSONValue.from(report)
        let text = String(decoding: try JSONCoding.encode(report), as: UTF8.self)
        for secret in ["private-set-name", "private-preset-name", "private-model-argument", "private-session-title", "private-initial-task", "sk-secret", "private-request-fingerprint", "private-error", "credential-value", "ghp_credential", "Bearer token", "eyJhbGci", "config=", "line\\nsecret", String(repeating: "a", count: 50), value.nativeConversationID!] {
            #expect(!text.contains(secret), "Unexpected private field: \(secret)")
        }
        #expect(json["sessions"].array[0]["configurationPath"].string == "/Users/test/.codexwho-personal")
        #expect(json["sessions"].array[0]["executablePath"].string == "/opt/bin/codex")
        #expect(json["sessions"].array[0]["executableVersion"].string == "0.154.0")
        #expect(json["sessions"].array[0]["workingDirectory"].string == "/Users/test/Project café")
        #expect(report.issues[1].code == .operation_failed)
        #expect(report.issues[1].path == nil)
        #expect(report.sessions[0].failureCode == .missing_directory)
        #expect(DiagnosticRedaction.version("2.1.272 (Claude Code)") == "2.1.272")
        for version in ["1.2.3\nsk-secret", "codex-cli 1.2.3 --token secret", "1.2.3-sk-secret", "sk-secret"] { #expect(DiagnosticRedaction.version(version) == nil) }
    }
    @Test func boundedReportsAndLegacyFailureRecords() throws {
        let value = session()
        let json = try JSONSerialization.jsonObject(with: JSONCoding.encode(value)) as! [String: Any]
        let legacy = json.filter { !["failureCode", "exitStatus"].contains($0.key) }
        let decoded = try JSONCoding.decode(Session.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.failureCode == nil && decoded.exitStatus == nil)
        #expect(DiagnosticSession(decoded).failureCode == .operation_failed)
        var worstCase = value
        worstCase.launch.workingDirectory = "/" + String(repeating: "folder/", count: 290)
        worstCase.launch.additionalPaths = Array(repeating: worstCase.launch.workingDirectory, count: 100)
        let report = DiagnosticsReport(sessions: Array(repeating: worstCase, count: 105), health: .null,
            errors: Array(repeating: ChauffeurError("invalid", "private"), count: 110), observation: .cached, observedAt: Date(timeIntervalSince1970: 123))
        #expect(report.sessions.count == 100 && report.omittedSessions == 5)
        #expect(report.sessions[0].omittedAdditionalPaths == 92)
        #expect(report.issues.count == 100 && report.omittedIssues == 10)
        #expect(report.observation == .cached && report.observedAt == Date(timeIntervalSince1970: 123))
        #expect(try JSONCoding.encode(report).count < 4 * 1024 * 1024)
    }
    @Test func exportIsPrivateAndReplacesDestinationWithoutFollowingLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside"), destination = root.appendingPathComponent("report.json")
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        let report = DiagnosticsReport(sessions: [], health: .null, errors: [], observation: .unavailable, observedAt: nil)
        try report.write(to: destination)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "preserve")
        #expect((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try JSONCoding.decode(DiagnosticsReport.self, from: Data(contentsOf: destination)).observation == .unavailable)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }
}
