import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// A Homebrew upgrade replaces the versioned directory a symlinked CLI resolves
/// to while sessions that started from it are still running.
struct ExecutableRefreshTests {
    @Test func upgradeWarnsTheRunningSessionAndResumeUsesTheInstalledVersion() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let fileManager = FileManager.default
        let script = fixture.path("fixture.py")
        let bin = fixture.path("bin"), link = bin.appendingPathComponent("agent")
        func install(_ version: String) throws -> URL {
            let directory = fixture.path("Caskroom/agent/\(version)/bin")
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("agent")
            try fileManager.copyItem(at: script, to: target)
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            return target
        }
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let old = try install("1.0.0")
        let set = try #require(await fixture.runtime.store.current().presetSets.first).value
        let preset = AgentPreset(setID: set.id, name: "Linked", kind: .claude, executable: link.path, configurationDirectory: fixture.root.path)
        try await fixture.runtime.store.save(preset)
        var request = fixture.request; request.presetID = preset.id

        let launched = try await fixture.runtime.launch(request)
        #expect(launched.launch.executablePath == Paths.canonical(old.path))
        try await fixture.runtime.reconcile()
        #expect(try await fixture.session().executableWarning == nil)

        // The upgrade removes the old version while the session runs.
        let new = try install("2.0.0")
        try fileManager.removeItem(at: fixture.path("Caskroom/agent/1.0.0"))
        try await fixture.runtime.reconcile()
        let warned = try await fixture.session()
        #expect(warned.state.isLive && warned.executableWarning?.contains("Resume") == true)

        _ = try await fixture.stop()
        try await fixture.runtime.reconcile()
        #expect(try await fixture.session().executableWarning == nil, "Only live sessions are warned")
        let resumed = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(launched.id.uuidString)]))).decode(Session.self)
        #expect(resumed.state.isLive && resumed.launch.executablePath == Paths.canonical(new.path))
        #expect(resumed.executableWarning == nil && resumed.nativeConversationID == launched.nativeConversationID)
        _ = try await fixture.stop()

        // With nothing installed, Resume refuses before touching the ended session.
        try fileManager.removeItem(at: link)
        let ended = try await fixture.session()
        var code: String?
        do { _ = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(launched.id.uuidString)]))) }
        catch let error as ChauffeurError { code = error.code }
        #expect(code == "missing_executable")
        #expect(try await fixture.session().state == ended.state)
    }
}
