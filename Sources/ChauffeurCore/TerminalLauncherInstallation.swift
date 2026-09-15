import Foundation
import Darwin

public enum TerminalLauncherInstallation {
    public static let destination = URL(fileURLWithPath: "/usr/local/bin/chauffeur")

    public static func install(executable: URL, at destination: URL = destination) throws {
        let manager = FileManager.default
        let source = executable.resolvingSymlinksInPath().standardizedFileURL
        guard manager.isExecutableFile(atPath: source.path) else { throw ChauffeurError("launcher_missing", "The bundled terminal command is missing") }
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFLNK,
                  let target = try? manager.destinationOfSymbolicLink(atPath: destination.path) else {
                throw ChauffeurError("launcher_conflict", "Another command already exists at \(destination.path)")
            }
            let existing = URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent()).standardizedFileURL
            if existing == source { return }
            let oldApp = existing.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard existing.lastPathComponent == "chauffeur-launcher", Bundle(url: oldApp)?.bundleIdentifier == "dev.chauffeur.app" else {
                throw ChauffeurError("launcher_conflict", "Another command already exists at \(destination.path)")
            }
        } else if errno != ENOENT {
            throw ChauffeurError("launcher_install", "Cannot inspect \(destination.path)")
        }
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".chauffeur-\(UUID().uuidString)")
        try manager.createSymbolicLink(at: temporary, withDestinationURL: source)
        defer { try? manager.removeItem(at: temporary) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw ChauffeurError("launcher_install", "Cannot install \(destination.path). Administrator access may be required")
        }
    }
}
