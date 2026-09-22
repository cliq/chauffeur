import Foundation
import Testing
import ChauffeurCore

struct RuntimeIdentityTests {
    @Test func inheritedManagedSocketDoesNotBypassRuntimeUpdates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("runtime.sock").path
        #expect(!RuntimeConnectionPolicy.usesCustomSocket(nil, defaultSocket: managed))
        #expect(!RuntimeConnectionPolicy.usesCustomSocket(managed, defaultSocket: managed))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(!RuntimeConnectionPolicy.usesCustomSocket(alias.appendingPathComponent("runtime.sock").path, defaultSocket: managed))
        #expect(RuntimeConnectionPolicy.usesCustomSocket(root.appendingPathComponent("fixture.sock").path, defaultSocket: managed))
        #expect(RuntimeConnectionPolicy.usesCustomSocket(
            AppBuild.debug.applicationSupport.appendingPathComponent("runtime/runtime.sock").path,
            defaultSocket: AppBuild.release.applicationSupport.appendingPathComponent("runtime/runtime.sock").path))
    }

    @Test func movingAnUnchangedAppRequiresNewRegistration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original-runtime")
        let moved = root.appendingPathComponent("moved-runtime")
        try Data("same executable".utf8).write(to: original)
        let before = try RuntimeIdentity(executable: original, dataRoot: root)
        try FileManager.default.moveItem(at: original, to: moved)
        let after = try RuntimeIdentity(executable: moved, dataRoot: root)
        #expect(before.executableDigest == after.executableDigest)
        #expect(before != after)
        #expect(before.registrationFingerprint(plist: Data()) != after.registrationFingerprint(plist: Data()))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: moved)
        #expect(try RuntimeIdentity(executable: alias, dataRoot: root) == after)
    }

    @Test func oldProcessesAndWrongBuildsCannotMatchANewInstallation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("runtime")
        try Data("old build".utf8).write(to: executable)
        let running = try RuntimeIdentity(build: .release, executable: executable, dataRoot: root)
        try Data("new build".utf8).write(to: executable, options: .atomic)
        let updated = try RuntimeIdentity(build: .release, executable: executable, dataRoot: root)
        #expect(running != updated)
        #expect(running.executablePath == updated.executablePath)
        #expect(try RuntimeIdentity(build: .debug, executable: executable, dataRoot: root) != updated)
        #expect(try RuntimeIdentity(build: .release, executable: executable, dataRoot: root.appendingPathComponent("other-store")) != updated)
        #expect(try JSONCoding.decode(RuntimeIdentity.self, from: JSONCoding.encode(updated)) == updated)
    }

    @Test func debugAndReleaseKeepDistinctStoresAndRouting() throws {
        #expect(AppBuild.release.applicationSupport.lastPathComponent == "Chauffeur")
        #expect(AppBuild.debug.applicationSupport != AppBuild.release.applicationSupport)
        #expect(AppBuild.debug.serviceLabel != AppBuild.release.serviceLabel)
        #expect(AppBuild.debug.notificationIdentifier != AppBuild.release.notificationIdentifier)
        #expect(AppBuild.debug.commandName != AppBuild.release.commandName)
        let route = SessionRoute(projectID: UUID(), sessionID: UUID())
        let other = AppBuild.current == .debug ? AppBuild.release : .debug
        let foreign = try #require(URL(string: route.url.absoluteString.replacingOccurrences(of: AppBuild.current.urlScheme + ":", with: other.urlScheme + ":")))
        #expect(SessionRoute(url: foreign) == nil)
    }
}
