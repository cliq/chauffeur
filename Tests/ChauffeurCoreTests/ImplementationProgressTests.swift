import Foundation
import Testing
@testable import ChauffeurCore

struct ImplementationProgressTests {
    static let legacy = #"{"title":"Build","subtitle":"Fixture","now":"Checking","updated":"2026-09-22T12:30:00+02:00","phases":[{"title":"One","detail":"","state":"done","steps":[]},{"title":"Two","detail":"","state":"active","steps":[{"title":"A","state":"done"},{"title":"B","state":"pending"}]}]}"#

    @Test func legacyAndVersionedDataDecodeWithTheSameEstimate() throws {
        let data = Data(Self.legacy.utf8)
        let legacy = try ImplementationProgress.decode(data)
        #expect(legacy.percentComplete == 75)
        #expect(legacy.updated.timeIntervalSince1970 == 1_790_073_000)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["schemaVersion"] = 1; object["percentComplete"] = 75
        let versioned = try ImplementationProgress.decode(JSONSerialization.data(withJSONObject: object))
        #expect(versioned == legacy)
        object["schemaVersion"] = 2
        #expect(throws: (any Error).self) { try ImplementationProgress.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func readerSeesAtomicReplacementsAndReportsMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("progress.json")
        #expect(throws: (any Error).self) { try ProgressFiles.read(jsonPath: path.path) }
        try Data(Self.legacy.utf8).write(to: path, options: .atomic)
        #expect(try ProgressFiles.read(jsonPath: path.path).now == "Checking")
        try Data(Self.legacy.replacingOccurrences(of: "Checking", with: "Finished").utf8).write(to: path, options: .atomic)
        #expect(try ProgressFiles.read(jsonPath: path.path).now == "Finished")
        try Data("{}".utf8).write(to: path, options: .atomic)
        #expect(throws: (any Error).self) { try ProgressFiles.read(jsonPath: path.path) }
        #expect(throws: (any Error).self) { try ProgressFiles.read(jsonPath: "relative.json") }
    }

    @Test func registrationSchemaDoesNotAcceptAnotherSession() throws {
        try MCPTools.validate(name: "chauffeur_register_progress", arguments: .object(["jsonPath": .string("/tmp/progress.json")]))
        #expect(throws: ChauffeurError.self) {
            try MCPTools.validate(name: "chauffeur_register_progress", arguments: .object(["jsonPath": .string("/tmp/progress.json"), "sessionID": .string(UUID().uuidString)]))
        }
        try MCPTools.validate(name: "chauffeur_unregister_progress", arguments: .object([:]))
    }

    @Test(arguments: ["state", "date", "percentage"]) func rejectsMalformedProgress(field: String) throws {
        var object = try JSONSerialization.jsonObject(with: Data(Self.legacy.utf8)) as! [String: Any]
        switch field {
        case "date": object["updated"] = "not a timestamp"
        case "percentage": object["percentComplete"] = 101
        default:
            var phases = object["phases"] as! [[String: Any]]
            phases[0]["state"] = "unknown"; object["phases"] = phases
        }
        #expect(throws: (any Error).self) { try ImplementationProgress.decode(JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func oversizedAndNonregularFilesAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = directory.appendingPathComponent("progress.json")
        try Data(repeating: 32, count: ProgressFiles.maximumJSONBytes + 1).write(to: oversized)
        #expect(throws: ChauffeurError.self) { try ProgressFiles.read(jsonPath: oversized.path) }
        #expect(throws: ChauffeurError.self) { try ProgressFiles.read(jsonPath: directory.path) }
        #expect(throws: ChauffeurError.self) { try ProgressFiles.htmlURL(directory.path) }
    }
}

struct ProgressMilestoneTests {
    private func progress(now: String = "Working", phases: [(String, String, [(String, String)])]) throws -> ImplementationProgress {
        let value: [String: Any] = ["title": "Task", "now": now, "updated": "2026-09-23T10:00:00Z",
            "phases": phases.map { ["title": $0.0, "detail": "", "state": $0.1, "steps": $0.2.map { ["title": $0.0, "state": $0.1] }] }]
        return try JSONCoding.decode(ImplementationProgress.self, from: JSONSerialization.data(withJSONObject: value))
    }
    @Test func onlyPhaseAndStepStatesAreMilestones() throws {
        let base = try progress(phases: [("Build", "active", [("Compile", "active")])])
        #expect(try !progress(now: "Still compiling", phases: [("Build", "active", [("Compile", "active")])]).changesMilestones(from: base))
        #expect(try progress(phases: [("Build", "active", [("Compile", "done")])]).changesMilestones(from: base))
        #expect(try progress(phases: [("Build", "blocked", [("Compile", "active")])]).changesMilestones(from: base))
        #expect(try progress(phases: [("Build", "active", [("Compile", "active"), ("Link", "pending")])]).changesMilestones(from: base))
        #expect(try progress(phases: [("Build", "active", [("Compile", "active")]), ("Verify", "pending", [])]).changesMilestones(from: base))
    }
}
