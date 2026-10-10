#if os(Linux)
import Glibc

/// A non-blocking inotify instance: Linux's file notifications, standing in for FSEvents.
/// Watches are per directory, not recursive. Not thread-safe; callers serialize access.
public final class Inotify: @unchecked Sendable {
    public struct Event: Sendable {
        public var watch: Int32
        public var mask: UInt32
        /// The entry's name inside the watched directory; empty for the directory itself.
        public var name: String
        public func contains(_ flags: Int32) -> Bool { mask & UInt32(bitPattern: flags) != 0 }
    }

    /// Entries created, removed, renamed or written in a directory, and the directory itself
    /// going away.
    public static let directoryChanges = Int32(IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_ATTRIB | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF | IN_ONLYDIR | IN_DONT_FOLLOW)

    public let descriptor: Int32

    public init?() {
        descriptor = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard descriptor >= 0 else { return nil }
    }

    deinit { close(descriptor) }

    /// The watch descriptor, or nil when the directory is gone or the user's watch limit
    /// (`fs.inotify.max_user_watches`) is reached.
    public func watch(_ path: String, mask: Int32 = Inotify.directoryChanges) -> Int32? {
        let watch = inotify_add_watch(descriptor, path, UInt32(bitPattern: mask))
        return watch >= 0 ? watch : nil
    }

    public func remove(_ watch: Int32) { _ = inotify_rm_watch(descriptor, watch) }

    /// Every event queued so far, without blocking.
    public func read() -> [Event] {
        var events: [Event] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return events }
            buffer.withUnsafeBytes { raw in
                var offset = 0
                // struct inotify_event: int wd; uint32_t mask, cookie, len; char name[len].
                while offset + 16 <= count {
                    let watch = raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
                    let mask = raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                    let length = Int(raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
                    let nameBytes = raw[(offset + 16)..<min(offset + 16 + length, count)]
                    let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
                    events.append(Event(watch: watch, mask: mask, name: name))
                    offset += 16 + length
                }
            }
        }
    }
}
#endif
