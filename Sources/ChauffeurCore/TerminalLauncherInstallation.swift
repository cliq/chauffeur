import Foundation
import Darwin

public enum TerminalLauncherInstallation {
    public static let destination = URL(fileURLWithPath: "/usr/local/bin/\(AppBuild.current.commandName)")
    // Keep the legacy ownership marker stable so installed commands remain
    // repairable after the app's bundle identifier changes.
    private static let marker = "#!/bin/sh\n# Managed by Chauffeur (dev.chauffeur.app).\n"

    private static func script(executable: URL) -> Data {
        Data((marker + "exec " + ArgumentText.format([executable.resolvingSymlinksInPath().standardizedFileURL.path]) + " \"$@\"\n").utf8)
    }

    public static func isInstalled(executable: URL, at destination: URL = destination) -> Bool {
        var info = stat()
        guard lstat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: destination.path) else { return false }
        return (try? Data(contentsOf: destination)) == script(executable: executable)
    }

    public static func install(executable: URL, at destination: URL = destination) throws {
        let manager = FileManager.default
        let source = executable.resolvingSymlinksInPath().standardizedFileURL
        guard manager.isExecutableFile(atPath: source.path) else { throw ChauffeurError("launcher_missing", "The bundled terminal command is missing") }
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            let owned: Bool
            if info.st_mode & S_IFMT == S_IFREG {
                // Ownership survives moving/deleting the prior app. A symlink
                // alone cannot prove who installed it once its target is gone.
                owned = (try? Data(contentsOf: destination).starts(with: Data(marker.utf8))) == true
            } else if info.st_mode & S_IFMT == S_IFLNK,
                      let target = try? manager.destinationOfSymbolicLink(atPath: destination.path) {
                // Upgrade an existing installation from the earlier symlink form.
                let existing = URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL
                let oldApp = existing.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                owned = existing == source || (existing.lastPathComponent == "chauffeur-launcher" && Bundle(url: oldApp)?.bundleIdentifier == "dev.chauffeur.app")
            } else {
                owned = false
            }
            guard owned else {
                throw ChauffeurError("launcher_conflict", "Another command already exists at \(destination.path)")
            }
            if isInstalled(executable: source, at: destination) { return }
        } else if errno != ENOENT {
            throw ChauffeurError("launcher_install", "Cannot inspect \(destination.path)")
        }
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".chauffeur-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        try script(executable: source).write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        guard rename(temporary.path, destination.path) == 0 else {
            throw ChauffeurError("launcher_install", "Cannot install \(destination.path). Administrator access may be required")
        }
    }
}
