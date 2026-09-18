import Foundation
import Darwin

/// One immutable handoff per owner lifetime. It contains no session commands or secrets.
public struct SessionOwnerManifest: Codable, Sendable {
    public let id: UUID
    public let appPath: String
    public let tmuxPath: String
    public let socketPath: String
    public let environment: [String: String]

    public init(id: UUID, appPath: String, tmuxPath: String, socketPath: String, environment: [String: String]) {
        self.id = id; self.appPath = appPath; self.tmuxPath = tmuxPath
        self.socketPath = socketPath; self.environment = environment
    }

    public static func configuration(scrollback: Int) -> Data {
        Data("set -g status off\nset -g prefix None\nset -g prefix2 None\nset -g mouse on\nset -g set-clipboard on\nset -g history-limit \(scrollback)\nset -g remain-on-exit on\nset -g exit-empty off\nset -g update-environment ''\nset -g default-terminal tmux-256color\n".utf8)
    }

    public static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validatePrivate(url, directory: true)
    }

    public static func validatePrivate(_ url: URL, directory: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw ChauffeurError("session_owner_permissions", "Sessions helper files must be private to the current user", path: url.path)
        }
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONCoding.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Held by the app, never inherited by its tmux child. A PID file alone is not liveness.
public final class SessionOwnerLock: @unchecked Sendable {
    private let descriptor: Int32
    public init(_ url: URL) throws {
        descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ChauffeurError("session_owner_lock", "Cannot open Sessions helper lock") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ChauffeurError("session_owner_busy", "Sessions helper is already running")
        }
    }
    deinit { Darwin.close(descriptor) }

    public static func isHeld(_ url: URL) -> Bool {
        let fd = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
    }
}
