import AppKit
import ChauffeurCore

@main @MainActor struct SessionsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = SessionsDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("Owns session privacy consent")
        ProcessInfo.processInfo.disableSuddenTermination()
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// LaunchServices gives this app its own responsibility lifetime. It deliberately
/// outlives both the desktop UI and the runtime. Quitting it never kills tmux.
@MainActor private final class SessionsDelegate: NSObject, NSApplicationDelegate {
    private var ownerLock: SessionOwnerLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await start() }
            catch { NSApplication.shared.terminate(nil) }
        }
    }

    private func start() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "--manifest" else { throw ChauffeurError("usage", "Expected a Sessions handoff") }
        let path = URL(fileURLWithPath: args[2])
        let directory = path.deletingLastPathComponent()
        try SessionOwnerManifest.validatePrivate(directory, directory: true)
        try SessionOwnerManifest.validatePrivate(path, directory: false)
        let manifest = try JSONCoding.decode(SessionOwnerManifest.self, from: Data(contentsOf: path))
        guard Paths.canonical(manifest.appPath) == Paths.canonical(Bundle.main.bundlePath),
              manifest.socketPath.utf8.count < 104 else { throw ChauffeurError("session_owner_manifest", "Invalid Sessions handoff") }
        ownerLock = try SessionOwnerLock(directory.appendingPathComponent("owner.lock"))
        // Never attach a new responsibility lifetime to an old server. The runtime
        // allocates a fresh directory/socket after a crash; surviving panes stay put.
        guard !FileManager.default.fileExists(atPath: manifest.socketPath) else {
            throw ChauffeurError("session_owner_socket", "Sessions socket already exists")
        }
        let config = directory.appendingPathComponent("tmux.conf")
        try SessionOwnerManifest.configuration(scrollback: 10_000).write(to: config, options: .atomic)
        _ = try await run(manifest, arguments: ["-S", manifest.socketPath, "-f", config.path, "start-server", ";", "set-option", "-g", "@chauffeur-owner", manifest.id.uuidString])
        try SessionOwnerManifest.write(getpid(), to: directory.appendingPathComponent("ready.json"))
        while true {
            try await Task.sleep(for: .seconds(5))
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("retired.json").path) else { continue }
            // The runtime no longer sends new sessions here. Check and stop the
            // empty server atomically inside tmux, never from a stale inventory.
            do {
                let result = try await run(manifest, arguments: ["-N", "-S", manifest.socketPath, "if-shell", "-F", "#{==:#{server_sessions},0}", "display-message -p retired ; kill-server", "display-message -p live"])
                if result.trimmingCharacters(in: .whitespacesAndNewlines) == "retired" {
                    NSApplication.shared.terminate(nil)
                    return
                }
            } catch { /* Unknown inventory is not permission to stop an owner. */ }
        }
    }

    private func run(_ manifest: SessionOwnerManifest, arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: manifest.tmuxPath)
        process.arguments = arguments
        process.environment = manifest.environment
        process.currentDirectoryURL = URL(fileURLWithPath: manifest.socketPath).deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // A bounded asynchronous wait keeps the app responsive during startup.
        for _ in 0..<200 where process.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        guard !process.isRunning, process.terminationStatus == 0 else {
            if process.isRunning { process.terminate() }
            throw ChauffeurError("session_owner_start", "Could not start Sessions terminal server")
        }
        return String(decoding: try output.fileHandleForReading.read(upToCount: 1024) ?? Data(), as: UTF8.self)
    }
}
