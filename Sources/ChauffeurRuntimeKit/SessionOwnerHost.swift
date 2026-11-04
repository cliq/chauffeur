import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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
            let manifest: SessionOwnerManifest
            do {
                try SessionOwnerManifest.validatePrivate(item, directory: true)
                try SessionOwnerManifest.validatePrivate(path, directory: false)
                manifest = try JSONCoding.decode(SessionOwnerManifest.self, from: Data(contentsOf: path))
            } catch where !FileManager.default.fileExists(atPath: item.path) {
                return nil // Pruned while listing: its owner had already finished.
            }
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
        // its sessions. Its cached bundle is pruned on a later start once unused.
        for (directory, manifest) in (try? Self.manifests(in: runtimeDirectory)) ?? [] where manifest.id != id {
            try? SessionOwnerManifest.write(true, to: directory.appendingPathComponent("retired.json"))
        }
    }

    private func healthy(_ directory: URL, _ manifest: SessionOwnerManifest) async throws -> Bool {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("retired.json").path),
              SessionOwnerLock.isHeld(directory.appendingPathComponent("owner.lock")),
              let data = try? Data(contentsOf: directory.appendingPathComponent("ready.json")),
              let pid = try? JSONCoding.decode(Int32.self, from: data), pid > 0 else { return false }
        guard let loadedPath = Platform.executablePath(processID: pid) else { return false }
        guard Paths.canonical(loadedPath) == Paths.canonical(manifest.appPath + "/Contents/MacOS/ChauffeurSessions") else { return false }
        let result = try await ProcessRunner.run(executable, ["-N", "-S", manifest.socketPath, "show-options", "-gqv", "@chauffeur-owner"], environment: environment, timeout: 3)
        return result.status == 0 && result.output.trimmingCharacters(in: .whitespacesAndNewlines) == manifest.id.uuidString
    }

    /// Copies of the helper live in a few reusable slots, `session-apps/slot-N`.
    /// macOS keeps a Local Network entry per helper path, so a fresh path per
    /// build would add an entry with every update. A running owner's copy is
    /// never replaced: TCC looks up its responsible executable on disk.
    func preservedApp() async throws -> URL {
        let binary = embeddedApp.appendingPathComponent("Contents/MacOS/ChauffeurSessions")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ChauffeurError("session_owner_missing", "Chauffeur Sessions is missing. Reinstall Chauffeur before starting new sessions")
        }
        let cache = cacheDirectory
        try SessionOwnerManifest.privateDirectory(cache)
        var owners: [(directory: URL, manifest: SessionOwnerManifest, inUse: Bool)] = []
        for (directory, manifest) in try Self.manifests(in: runtimeDirectory) {
            owners.append((directory, manifest, await inUse(directory, manifest)))
        }
        let busy = Set(owners.filter(\.inUse).compactMap { cacheEntry(containing: $0.manifest.appPath) })
        let slots = ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? [])
            .compactMap { name in Self.slotIndex(name).map { (index: $0, name: name) } }.sorted { $0.index < $1.index }
        var chosen: String?
        // Reconnecting to an unchanged build keeps its slot.
        for slot in slots {
            let app = cache.appendingPathComponent(slot.name).appendingPathComponent(Self.appName)
            if matchesEmbedded(app), (try? await verify(app)) != nil { chosen = slot.name; break }
        }
        if chosen == nil {
            let name = (1...).lazy.map { "slot-\($0)" }.first { !busy.contains($0) }!
            try await install(into: cache.appendingPathComponent(name))
            chosen = name
        }
        let app = cache.appendingPathComponent(chosen!).appendingPathComponent(Self.appName)
        try await verify(app)
        guard matchesEmbedded(app) else {
            throw ChauffeurError("session_owner_signature", "Cached Sessions helper differs from the installed build")
        }
        prune(owners: owners, busy: busy, keeping: chosen!)
        return app
    }

    static let appName = "Chauffeur Sessions.app"
    private var cacheDirectory: URL { runtimeDirectory.deletingLastPathComponent().appendingPathComponent("session-apps") }
    static func slotIndex(_ name: String) -> Int? {
        guard name.hasPrefix("slot-"), let index = Int(name.dropFirst(5)), index > 0, name == "slot-\(index)" else { return nil }
        return index
    }

    /// The entry directly under the cache that holds this app, if any.
    private func cacheEntry(containing appPath: String) -> String? {
        let app = URL(fileURLWithPath: Paths.canonical(appPath))
        let entry = app.deletingLastPathComponent()
        guard Paths.canonical(entry.deletingLastPathComponent().path) == Paths.canonical(cacheDirectory.path) else { return nil }
        return entry.lastPathComponent
    }

    private func matchesEmbedded(_ app: URL) -> Bool {
        func same(_ relative: String) -> Bool {
            guard let copy = try? Data(contentsOf: app.appendingPathComponent(relative)),
                  let source = try? Data(contentsOf: embeddedApp.appendingPathComponent(relative)) else { return false }
            return copy == source
        }
        return same("Contents/MacOS/ChauffeurSessions") && same("Contents/Info.plist")
    }

    /// Swaps a slot's contents for the embedded build. The old directory is
    /// renamed away first, so no running process ever sees a half-written copy.
    private func install(into slot: URL) async throws {
        let cache = slot.deletingLastPathComponent()
        let stage = cache.appendingPathComponent(".stage-\(UUID())")
        try SessionOwnerManifest.privateDirectory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let copy = stage.appendingPathComponent(Self.appName)
        try FileManager.default.copyItem(at: embeddedApp, to: copy)
        try await verify(copy)
        if FileManager.default.fileExists(atPath: slot.path) {
            let trash = cache.appendingPathComponent(".trash-\(UUID())")
            try FileManager.default.moveItem(at: slot, to: trash)
            try? FileManager.default.removeItem(at: trash)
        }
        try FileManager.default.moveItem(at: stage, to: slot)
    }

    /// An owner is in use while its app holds the lock or its tmux server still
    /// answers: an exited owner's server keeps live sessions. Only a server
    /// tmux reports as absent frees it; unknown state never does.
    private func inUse(_ directory: URL, _ manifest: SessionOwnerManifest) async -> Bool {
        if SessionOwnerLock.isHeld(directory.appendingPathComponent("owner.lock")) { return true }
        guard let result = try? await ProcessRunner.run(executable, ["-N", "-S", manifest.socketPath, "list-sessions"], environment: environment, timeout: 3) else { return true }
        if result.status == 0 { return true }
        return !["no server running", "No such file", "Connection refused"].contains { result.error.contains($0) }
    }

    /// Best effort: removes records of finished owners, then every cached copy
    /// that is neither the current slot nor used by a remaining owner.
    private func prune(owners: [(directory: URL, manifest: SessionOwnerManifest, inUse: Bool)], busy: Set<String>, keeping current: String) {
        let manager = FileManager.default
        for owner in owners where !owner.inUse {
            try? manager.removeItem(at: owner.directory)
            // manifests(in:) checked that the socket lives in the runtime directory.
            if manager.fileExists(atPath: owner.manifest.socketPath) { try? manager.removeItem(atPath: owner.manifest.socketPath) }
        }
        let cache = cacheDirectory
        for name in (try? manager.contentsOfDirectory(atPath: cache.path)) ?? [] where name != current && !busy.contains(name) {
            let item = cache.appendingPathComponent(name)
            if name.hasPrefix(".") {
                // A concurrent install may still be staging; only old leftovers go.
                let modified = (try? manager.attributesOfItem(atPath: item.path)[.modificationDate] as? Date) ?? Date()
                guard Date().timeIntervalSince(modified) > 600 else { continue }
            }
            try? manager.removeItem(at: item)
        }
    }

    private func verify(_ app: URL) async throws {
        let result = try await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], timeout: 10)
        guard result.status == 0 else { throw ChauffeurError("session_owner_signature", "Sessions helper signature is invalid. Reinstall Chauffeur") }
    }
}
