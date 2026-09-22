import Foundation
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

struct RemoteProgressTests {
    @Test func registeredFilesProduceSummaryAndFullHTMLAndTrackAtomicChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-progress-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("progress.json"), html = root.appendingPathComponent("index.html")
        func write(_ now: String, percent: Int) throws {
            try JSONSerialization.data(withJSONObject: ["title": "Task", "now": now, "phases": [], "percentComplete": percent, "updated": "2026-09-22T12:00:00Z"])
                .write(to: json, options: .atomic)
        }
        try write("Building", percent: 25)
        try "<html><script src='progress.js'></script><body>Full panel</body></html>".write(to: html, atomically: true, encoding: .utf8)
        var session = LedgerTests().session(project: UUID(), group: UUID())
        #expect(RemoteProgressReader.summary(session: session) == nil)
        #expect(throws: ChauffeurError.self) { try RemoteProgressReader.panel(session: session) }
        session.progress = ProgressRegistration(jsonPath: json.path, htmlPath: html.path)
        let first = try RemoteProgressReader.panel(session: session)
        #expect(first.sessionID == session.id && first.summary.percentComplete == 25)
        #expect(first.html?.contains("Full panel") == true)
        #expect(try ImplementationProgress.decode(Data(first.json.utf8)).now == "Building")
        try write("Verifying", percent: 75)
        #expect(RemoteProgressReader.summary(session: session)?.percentComplete == 75)
        #expect(try RemoteProgressReader.panel(session: session).summary.now == "Verifying")
        try FileManager.default.removeItem(at: html)
        let missingHTML = try RemoteProgressReader.panel(session: session)
        #expect(missingHTML.html == nil && missingHTML.htmlError != nil)
        try Data("partial".utf8).write(to: json)
        #expect(RemoteProgressReader.summary(session: session)?.error != nil)
        #expect(throws: (any Error).self) { try RemoteProgressReader.panel(session: session) }
    }

    @Test func oversizedAndNonRegularProgressFilesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-progress-size-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("progress.json")
        try Data(repeating: 32, count: ProgressFiles.maximumJSONBytes + 1).write(to: path)
        #expect(throws: ChauffeurError.self) { try ProgressFiles.readData(path: path.path) }
        #expect(throws: ChauffeurError.self) { try ProgressFiles.readData(path: root.path) }
    }
}
