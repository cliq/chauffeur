import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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
        // tmux runs a lone command string through its default shell. Without a
        // SHELL or passwd entry that is dash, which keeps itself as the foreground
        // process instead of exec-ing its last command as bash and zsh do.
        let created = try await ProcessRunner.run(fixture.tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", sessionID.uuidString, "exec /bin/cat"])
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
        let root = URL(fileURLWithPath: Paths.canonical("/tmp")).appendingPathComponent("ch-owner-\(UUID())")
        try SessionOwnerManifest.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = SessionOwnerHost(runtimeDirectory: root, embeddedApp: root.appendingPathComponent("missing.app"), executable: "/opt/homebrew/bin/tmux", environment: [:])
        await #expect(throws: ChauffeurError.self) { _ = try await owner.socket() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("tmux.sock").path))
    }

    @Test func helperCopiesReuseFreeSlotsAndPruneUnusedOnes() async throws {
        let root = URL(fileURLWithPath: Paths.canonical("/tmp")).appendingPathComponent("ch-slots-\(UUID())")
        try SessionOwnerManifest.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeDirectory = root.appendingPathComponent("runtime"), cache = root.appendingPathComponent("session-apps")
        try SessionOwnerManifest.privateDirectory(runtimeDirectory)
        let tmux = try Paths.executable("tmux", environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"])
        let embedded = root.appendingPathComponent("embedded/ChauffeurSessions.app")
        // Each build differs in a byte of its Info.plist; an ad-hoc signature seals it.
        func build(_ version: Int) async throws {
            try? FileManager.default.removeItem(at: embedded)
            try FileManager.default.createDirectory(at: embedded.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: embedded.appendingPathComponent("Contents/MacOS/ChauffeurSessions").path)
            let plist: [String: Any] = ["CFBundleIdentifier": "dev.chauffeur.slot-test", "CFBundleExecutable": "ChauffeurSessions", "CFBundlePackageType": "APPL", "CFBundleVersion": "\(version)"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: embedded.appendingPathComponent("Contents/Info.plist"))
            #expect(try await ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", embedded.path]).status == 0)
        }
        func owner(appPath: String) throws -> URL {
            let id = UUID(), directory = runtimeDirectory.appendingPathComponent("session-owners/\(id.uuidString)")
            try SessionOwnerManifest.privateDirectory(directory)
            let manifest = SessionOwnerManifest(id: id, appPath: appPath, tmuxPath: tmux, socketPath: runtimeDirectory.appendingPathComponent("tmux-\(id.uuidString.prefix(12)).sock").path, environment: [:])
            try SessionOwnerManifest.write(manifest, to: directory.appendingPathComponent("manifest.json"))
            return directory
        }
        let host = SessionOwnerHost(runtimeDirectory: runtimeDirectory, embeddedApp: embedded, executable: tmux, environment: [:])
        func slot(_ index: Int) -> String { cache.appendingPathComponent("slot-\(index)/\(SessionOwnerHost.appName)").path }
        func entries() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)) }

        try await build(1)
        #expect(try await host.preservedApp().path == slot(1))
        #expect(try await host.preservedApp().path == slot(1), "An unchanged build keeps its slot")
        // A running owner pins slot 1, so the next build takes slot 2.
        let running = try owner(appPath: slot(1))
        var lock: SessionOwnerLock? = try SessionOwnerLock(running.appendingPathComponent("owner.lock"))
        // Legacy per-build copies: one still used by a running owner, one not.
        let legacyLive = cache.appendingPathComponent("abc-live"), legacyDead = cache.appendingPathComponent("abc-dead")
        for item in [legacyLive, legacyDead] { try FileManager.default.createDirectory(at: item.appendingPathComponent(SessionOwnerHost.appName), withIntermediateDirectories: true) }
        let legacyOwner = try owner(appPath: legacyLive.appendingPathComponent(SessionOwnerHost.appName).path)
        let legacyLock = try SessionOwnerLock(legacyOwner.appendingPathComponent("owner.lock"))
        let finished = try owner(appPath: legacyDead.appendingPathComponent(SessionOwnerHost.appName).path)
        try await build(2)
        #expect(try await host.preservedApp().path == slot(2))
        #expect(try entries() == ["slot-1", "slot-2", "abc-live"], "Unused legacy copies go; running owners keep theirs")
        #expect(!FileManager.default.fileExists(atPath: finished.path) && FileManager.default.fileExists(atPath: running.path))
        // An exited owner whose tmux server still holds sessions keeps its record and copy.
        #expect(lock != nil); lock = nil
        let session = UUID().uuidString
        let socket = try JSONCoding.decode(SessionOwnerManifest.self, from: Data(contentsOf: running.appendingPathComponent("manifest.json"))).socketPath
        #expect(try await ProcessRunner.run(tmux, ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", session, "exec /bin/cat"]).status == 0)
        do {
            try await build(3)
            // Slot 2 has no owner, so the build replaces it in place.
            #expect(try await host.preservedApp().path == slot(2))
            #expect(try entries() == ["slot-1", "slot-2", "abc-live"] && FileManager.default.fileExists(atPath: running.path))
        } catch {
            _ = try? await ProcessRunner.run(tmux, ["-N", "-S", socket, "kill-server"])
            throw error
        }
        // Once that server exits too, the next build reuses slot 1 and slot 2 goes.
        _ = try await ProcessRunner.run(tmux, ["-N", "-S", socket, "kill-server"])
        try await build(4)
        #expect(try await host.preservedApp().path == slot(1))
        #expect(try entries() == ["slot-1", "abc-live"])
        #expect(!FileManager.default.fileExists(atPath: running.path) && FileManager.default.fileExists(atPath: legacyOwner.path))
        withExtendedLifetime(legacyLock) {}
    }

    @Test func ownerLockLivenessDoesNotDependOnStalePIDFiles() throws {
        let root = URL(fileURLWithPath: Paths.canonical("/tmp")).appendingPathComponent("ch-owner-\(UUID())")
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
