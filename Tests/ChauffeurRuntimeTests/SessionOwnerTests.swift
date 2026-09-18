import Foundation
import Darwin
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct SessionOwnerTests {
    @Test func routesLegacyAndSurvivingOwnerServersAfterRestart() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let legacy = try await fixture.runtime.launch(fixture.request)
        let runtimeDirectory = fixture.path("runtime")
        let owners = runtimeDirectory.appendingPathComponent("session-owners")
        try SessionOwnerManifest.privateDirectory(owners)
        let ownerID = UUID(), sessionID = UUID()
        let directory = owners.appendingPathComponent(ownerID.uuidString)
        try SessionOwnerManifest.privateDirectory(directory)
        let socket = runtimeDirectory.appendingPathComponent("second.sock").path
        let manifest = SessionOwnerManifest(id: ownerID, appPath: "/missing/old-owner.app", tmuxPath: fixture.tmux, socketPath: socket, environment: [:])
        try SessionOwnerManifest.write(manifest, to: directory.appendingPathComponent("manifest.json"))
        let created = try await ProcessRunner.run(fixture.tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", sessionID.uuidString, "/bin/cat"])
        #expect(created.status == 0)
        let host = try TmuxHost(runtimeDirectory: runtimeDirectory, ctlPath: "/bin/false", environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"])
        do {
            #expect(Set(try await host.inventory().map(\.sessionName)) == [legacy.id.uuidString, sessionID.uuidString])
            let oldSnapshot = try await host.capture(sessionID: legacy.id, lines: 10)
            #expect(oldSnapshot.processID == legacy.processID)
            let generation = try await host.attach(sessionID: sessionID, sink: DiscardSink(), cols: 91, rows: 29, takeControl: false)
            try await host.input(sessionID: sessionID, generation: generation, bytes: Data("second server\n".utf8))
            try await fixture.wait { try await host.capture(sessionID: sessionID, lines: 10).screen.contains("second server") }
            try await host.resize(sessionID: sessionID, generation: generation, cols: 87, rows: 28)
            #expect(try await host.foregroundCommand(sessionID: sessionID) == "cat")
            let replacement = try await host.attach(sessionID: legacy.id, sink: DiscardSink(), cols: 90, rows: 28, takeControl: false)
            #expect(replacement > generation, "Attachment generations remain global across servers")
            await host.detach(sessionID: sessionID, generation: generation)
            await host.detach(sessionID: legacy.id, generation: replacement)
            try await host.stop(sessionID: sessionID, force: true)
            #expect(try await host.inventory().map(\.sessionName) == [legacy.id.uuidString])
            #expect(try await host.foregroundCommand(sessionID: sessionID) == nil)
            #expect(try await host.capture(sessionID: legacy.id, lines: 10).processID == oldSnapshot.processID)
        } catch {
            _ = try? await ProcessRunner.run(fixture.tmux, ["-N", "-S", socket, "kill-server"])
            throw error
        }
        _ = try? await ProcessRunner.run(fixture.tmux, ["-N", "-S", socket, "kill-server"])
    }

    @Test func missingPackagedHelperFailsWithoutStartingDirectServer() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/ch-owner-\(UUID())")
        try SessionOwnerManifest.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = SessionOwnerHost(runtimeDirectory: root, embeddedApp: root.appendingPathComponent("missing.app"), executable: "/opt/homebrew/bin/tmux", environment: [:])
        await #expect(throws: ChauffeurError.self) { _ = try await owner.socket() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tmux.sock").path))
    }

    @Test func ownerLockLivenessDoesNotDependOnStalePIDFiles() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ch-owner-\(UUID())")
        try SessionOwnerManifest.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("owner.lock")
        #expect(!SessionOwnerLock.isHeld(path))
        do {
            let lock = try SessionOwnerLock(path)
            #expect(SessionOwnerLock.isHeld(path))
            #expect(throws: ChauffeurError.self) { _ = try SessionOwnerLock(path) }
            withExtendedLifetime(lock) {}
        }
        #expect(!SessionOwnerLock.isHeld(path))
    }
}

private final class DiscardSink: TerminalOutputSink {
    func write(_ bytes: Data) async throws {}
    func close(reason: AttachmentEndReason, message: String?) async {}
}
