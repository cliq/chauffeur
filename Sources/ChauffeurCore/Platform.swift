import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process and host facts that macOS and Linux expose differently.
public enum Platform {
    /// The loaded executable, independent of argv[0] and the working directory: launchd
    /// may pass a bundle-relative path as argv[0].
    public static func currentExecutable() throws -> URL {
        #if os(Linux)
        let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")
        #else
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var bytes = [CChar](repeating: 0, count: Int(size))
        let path = _NSGetExecutablePath(&bytes, &size) == 0 ? String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        #endif
        guard let path else { throw ChauffeurError("missing_helper", "Cannot locate the running runtime executable") }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    /// The executable a running process loaded, or nil when it has exited or belongs to another user.
    public static func executablePath(processID: pid_t) -> String? {
        #if os(Linux)
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(processID)/exe")
        #else
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(processID, &path, UInt32(path.count)) > 0 else { return nil }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }

    /// The user's shell: `SHELL` when set, otherwise the account's entry. systemd user
    /// services, unlike a login session, start without `SHELL`.
    public static func loginShell(environment: [String: String]) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell.map({ String(cString: $0) }), !shell.isEmpty { return shell }
        #if os(Linux)
        return "/bin/sh"
        #else
        return "/bin/zsh"
        #endif
    }

    /// The name shown to paired devices: the Mac's computer name, or the Linux host name.
    public static var hostDisplayName: String {
        #if os(macOS)
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    /// Linux has no per-socket `SO_NOSIGPIPE`, and OpenSSL writes to its sockets with plain
    /// `write`, so a peer that disconnects mid-write would end the process. A no-op handler
    /// rather than `SIG_IGN`: exec resets handlers to the default, while an ignored SIGPIPE
    /// would carry into every shell, agent and git child (`yes | head` would never stop).
    /// Does nothing on macOS, where sockets opt out individually.
    public static func installNoOpSIGPIPEHandler() {
        #if os(Linux)
        signal(SIGPIPE) { _ in }
        #endif
    }

    /// Runs `body`, which starts a Foundation `Process`, with no signals blocked. On Linux the
    /// child inherits the calling thread's mask, and Swift concurrency and Dispatch threads
    /// block nearly everything: a tmux server started that way never sees SIGCHLD, so its
    /// panes never die. Does nothing on macOS, where `Process` resets the mask itself.
    public static func withDefaultSignalMask<T>(_ body: () throws -> T) rethrows -> T {
        #if os(Linux)
        var empty = sigset_t(), saved = sigset_t()
        sigemptyset(&empty)
        pthread_sigmask(SIG_SETMASK, &empty, &saved)
        defer { pthread_sigmask(SIG_SETMASK, &saved, nil) }
        #endif
        return try body()
    }
}
