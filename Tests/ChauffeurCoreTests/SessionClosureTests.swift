import Foundation
import Testing
import ChauffeurCore

struct SessionClosureTests {
    private func session() -> Session {
        let set = PresetSet(name: "Test")
        let preset = AgentPreset(setID: set.id, name: "Agent", kind: .claude,
            executable: "/bin/cat", configurationDirectory: "/tmp")
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat",
            executableVersion: "fixture", workingDirectory: "/tmp", additionalPaths: [])
        var session = Session(projectID: UUID(), groupID: UUID(), title: "Worker", launch: launch, folderID: UUID())
        session.state = .interrupted
        return session
    }

    @Test func legacyClosuresDecodeWithoutGuessingTheClosingAgent() throws {
        var worker = session()
        worker.parentID = UUID()
        worker.closureOutcome = "accepted"
        worker.closureReason = "Handoff received"
        // Optional attribution fields are absent in records written by older versions.
        let decoded = try JSONCoding.decode(Session.self, from: JSONCoding.encode(worker))
        #expect(decoded.closedBySessionID == nil)
        #expect(decoded.statusLabel == "Closed by agent")
        #expect(decoded.closureSummary == "Closed by agent · Accepted")
        #expect(decoded.closureReason == "Handoff received")
    }

    @Test func ordinaryInterruptionsKeepTheirStatus() {
        let worker = session()
        #expect(worker.statusLabel == "Interrupted")
        #expect(worker.closureSummary == nil)
    }

    @Test func closureKeepsTheCallersIdentityAfterSerialization() throws {
        var worker = session()
        worker.closureOutcome = "replaced"
        worker.closedBySessionID = UUID()
        worker.closedBySessionTitle = "Review coordinator"
        let decoded = try JSONCoding.decode(Session.self, from: JSONCoding.encode(worker))
        #expect(decoded.closedBySessionID == worker.closedBySessionID)
        #expect(decoded.closureSummary == "Closed by agent “Review coordinator” · Replaced")
    }
}
