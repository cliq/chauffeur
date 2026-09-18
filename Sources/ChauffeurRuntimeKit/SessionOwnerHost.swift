import Foundation
import Darwin
import ChauffeurCore

/// Starts only fresh servers through LaunchServices. No shutdown hook: ownership
/// and AppData consent must survive runtime restarts and app replacement.
actor SessionOwnerHost {
    let runtimeDirectory: URL
    let embeddedApp: URL
    let executable: String
    let environment: [String: String]
    private var starting: Task<String, Error>?

    init(runtimeDirectory: URL, embeddedApp: URL, executable: String, environment: [String: String]) {
        self.runtimeDirectory = runtimeDirectory; self.embeddedApp = embeddedApp
        self.executable = executable; self.environment = environment
    }

    private var ownersDirectory: URL { runtimeDirectory.appendingPathComponent("session-owners") }

    func socket() async throws -> String {
        if let starting { return try await starting.value }
        let task = Task { try await self.startOrReconnect() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    /// Includes exited owners: their tmux servers still hold live sessions.
    static func manifests(in runtimeDirectory: URL) throws -> [(URL, SessionOwnerManifest)] {
        let directory = runtimeDirectory.appendingPathComponent("session-owners")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try SessionOwnerManifest.validatePrivate(directory, directory: true)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }.compactMap { item in
            guard UUID(uuidString: item.lastPathComponent) != nil else { return nil }
            let path = item.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            try SessionOwnerManifest.validatePrivate(item, directory: true)
            try SessionOwnerManifest.validatePrivate(path, directory: false)
            let manifest = try JSONCoding.decode(SessionOwnerManifest.self, from: Data(contentsOf: path))
            guard manifest.id.uuidString == item.lastPathComponent,
                  Paths.canonical(URL(fileURLWithPath: manifest.socketPath).deletingLastPathComponent().path) == Paths.canonical(runtimeDirectory.path) else {
                throw ChauffeurError("session_owner_manifest", "Invalid Sessions server record")
            }
            return (item, manifest)
        }
    }

    private func startOrReconnect() async throws -> String {
        let app = try await preservedApp()
        try SessionOwnerManifest.privateDirectory(ownersDirectory)
        for (directory, manifest) in try Self.manifests(in: runtimeDirectory) where manifest.appPath == app.path {
            if try await healthy(directory, manifest) {
                retireOthers(except: manifest.id)
                return manifest.socketPath
            }
        }
        let id = UUID()
        let directory = ownersDirectory.appendingPathComponent(id.uuidString)
        try SessionOwnerManifest.privateDirectory(directory)
        let socket = runtimeDirectory.appendingPathComponent("tmux-\(id.uuidString.prefix(12)).sock").path
        guard socket.utf8.count < 104 else { throw ChauffeurError("session_owner_socket", "Sessions socket path is too long", path: socket) }
        let manifest = SessionOwnerManifest(id: id, appPath: app.path, tmuxPath: executable, socketPath: socket, environment: environment)
        let path = directory.appendingPathComponent("manifest.json")
        try SessionOwnerManifest.write(manifest, to: path)
        // -n is essential: an older owner with the same bundle identifier cannot
        // adopt a new server's lifetime. -g keeps this invisible to the desktop.
        let result = try await ProcessRunner.run("/usr/bin/open", ["-n", "-g", "-a", app.path, "--args", "--manifest", path.path], timeout: 10)
        guard result.status == 0 else { throw ChauffeurError("session_owner_launch", "Could not open Chauffeur Sessions. Reinstall Chauffeur and try again") }
        for _ in 0..<200 {
            if try await healthy(directory, manifest) {
                retireOthers(except: id)
                return socket
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ChauffeurError("session_owner_timeout", "Chauffeur Sessions did not start. Existing sessions are still available")
    }

    private func retireOthers(except id: UUID) {
        // A failed retirement write may retain an idle helper, but cannot disrupt
        // its sessions. Signed cached bundles are deliberately never unlinked.
        for (directory, manifest) in (try? Self.manifests(in: runtimeDirectory)) ?? [] where manifest.id != id {
            try? SessionOwnerManifest.write(true, to: directory.appendingPathComponent("retired.json"))
        }
    }

    private func healthy(_ directory: URL, _ manifest: SessionOwnerManifest) async throws -> Bool {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("retired.json").path),
              SessionOwnerLock.isHeld(directory.appendingPathComponent("owner.lock")),
              let data = try? Data(contentsOf: directory.appendingPathComponent("ready.json")),
              let pid = try? JSONCoding.decode(Int32.self, from: data), pid > 0 else { return false }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let loadedPath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard Paths.canonical(loadedPath) == Paths.canonical(manifest.appPath + "/Contents/MacOS/ChauffeurSessions") else { return false }
        let result = try await ProcessRunner.run(executable, ["-N", "-S", manifest.socketPath, "show-options", "-gqv", "@chauffeur-owner"], environment: environment, timeout: 3)
        return result.status == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == manifest.id.uuidString
    }

    private func preservedApp() async throws -> URL {
        let binary = embeddedApp.appendingPathComponent("Contents/MacOS/ChauffeurSessions")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ChauffeurError("session_owner_missing", "Chauffeur Sessions is missing. Reinstall Chauffeur before starting new sessions")
        }
        // Include signed executable and plist. Each version has an immutable path;
        // retaining old copies preserves TCC's responsible executable lookup.
        let fingerprint = JSONCoding.digest(try Data(contentsOf: binary)) + "-" + JSONCoding.digest(try Data(contentsOf: embeddedApp.appendingPathComponent("Contents/Info.plist"))).prefix(12)
        let cache = runtimeDirectory.deletingLastPathComponent().appendingPathComponent("session-apps")
        try SessionOwnerManifest.privateDirectory(cache)
        let version = cache.appendingPathComponent(fingerprint)
        let app = version.appendingPathComponent("Chauffeur Sessions.app")
        if !FileManager.default.fileExists(atPath: app.path) {
            let stage = cache.appendingPathComponent(".stage-\(UUID())")
            try SessionOwnerManifest.privateDirectory(stage)
            defer { try? FileManager.default.removeItem(at: stage) }
            let copy = stage.appendingPathComponent(app.lastPathComponent)
            try FileManager.default.copyItem(at: embeddedApp, to: copy)
            try await verify(copy)
            try FileManager.default.moveItem(at: stage, to: version)
        }
        try await verify(app)
        guard try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/ChauffeurSessions")) == Data(contentsOf: binary),
              try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) == Data(contentsOf: embeddedApp.appendingPathComponent("Contents/Info.plist")) else {
            throw ChauffeurError("session_owner_signature", "Cached Sessions helper differs from the installed build")
        }
        return app
    }

    private func verify(_ app: URL) async throws {
        let result = try await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 10)
        guard result.status == 0 else { throw ChauffeurError("session_owner_signature", "Sessions helper signature is invalid. Reinstall Chauffeur") }
    }
}
