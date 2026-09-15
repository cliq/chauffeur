import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct RuntimeLogTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-logs-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func rotationSurvivesReopenAndKeepsPrivateBoundedFiles() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let logs = try RuntimeLogStore(root: root, maximumBytes: 1024)
        let unknown = root.appendingPathComponent("unrelated.log"); try Data("preserve".utf8).write(to: unknown)
        let runtimeID = UUID(), sessionID = UUID()
        for count in 0..<100 {
            var event = RuntimeLogEntry(.sessionChanged, runtimeID: runtimeID)
            event.sessionID = sessionID; event.state = .activityUnknown; event.count = count
            logs.append(event)
        }
        let reopened = try RuntimeLogStore(root: root, maximumBytes: 1024)
        let recent = reopened.recent(limit: 3)
        #expect(recent.status == .available && recent.discardedLines == 0)
        #expect(recent.entries.map(\.count) == [97, 98, 99])
        #expect(recent.entries.allSatisfy { $0.runtimeID == runtimeID && $0.sessionID == sessionID })
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        #expect(files.count == 4)
        for file in files {
            #expect(try Data(contentsOf: file).count <= 1024)
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try String(contentsOf: unknown, encoding: .utf8) == "preserve")
    }
    @Test func untrustedLogLinesAreDecodedThroughTheClosedSchema() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let logs = try RuntimeLogStore(root: root)
        let event = RuntimeLogEntry(.runtimeReady, runtimeID: UUID())
        var fields = try JSONSerialization.jsonObject(with: JSONCoding.encode(event)) as! [String: Any]
        fields["unknown"] = "private-config-content"
        var data = try JSONSerialization.data(withJSONObject: fields); data.append(0x0a)
        fields["code"] = "sk-private-error-code"
        data.append(try JSONSerialization.data(withJSONObject: fields)); data.append(0x0a)
        fields["code"] = "invalid"; fields["schemaVersion"] = 99
        data.append(try JSONSerialization.data(withJSONObject: fields)); data.append(Data("\nnot-json-secret\n".utf8))
        try data.write(to: root.appendingPathComponent("runtime.jsonl"))
        let report = logs.recent()
        #expect(report.entries.count == 1 && report.discardedLines == 3)
        let exported = String(decoding: try JSONCoding.encode(report), as: UTF8.self)
        #expect(!exported.contains("private") && !exported.contains("secret"))
    }
    @Test func unsafeFilesDisableLoggingWithoutChangingTheirTargets() throws {
        let parent = try root(); defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside")
        try Data("preserve".utf8).write(to: outside)
        for hardLink in [false, true] {
            let directory = parent.appendingPathComponent(hardLink ? "hard" : "symbolic")
            let logs = try RuntimeLogStore(root: directory, maximumBytes: 1024)
            let archive = directory.appendingPathComponent("runtime.3.jsonl")
            if hardLink { try FileManager.default.linkItem(at: outside, to: archive) }
            else { try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: outside) }
            logs.append(RuntimeLogEntry(.runtimeStarting, runtimeID: UUID()))
            #expect(logs.recent().status == .unavailable)
            #expect(try String(contentsOf: outside, encoding: .utf8) == "preserve")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime.jsonl").path))
        }
        let link = parent.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
        #expect(throws: (any Error).self) { _ = try RuntimeLogStore(root: link) }
        let oversizedRoot = parent.appendingPathComponent("oversized")
        let oversized = try RuntimeLogStore(root: oversizedRoot, maximumBytes: 1024)
        let file = oversizedRoot.appendingPathComponent("runtime.jsonl")
        try Data(repeating: 65, count: 1025).write(to: file)
        oversized.append(RuntimeLogEntry(.runtimeReady, runtimeID: UUID()))
        #expect(oversized.recent().status == .unavailable)
        #expect(try Data(contentsOf: file).count == 1025)
    }
}
