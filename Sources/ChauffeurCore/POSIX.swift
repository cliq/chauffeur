#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The C library calls that types with same-named methods (`close()`, `read(_:)`) make
/// on their descriptors, where an unqualified call would resolve to the method. Spelled
/// the same on macOS and Linux, unlike `Darwin.close` and `Glibc.close`.
public enum POSIX {
    @discardableResult public static func close(_ descriptor: Int32) -> Int32 { systemClose(descriptor) }
    public static func open(_ path: String, _ flags: Int32) -> Int32 { systemOpen(path, flags) }
    public static func open(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { systemOpen(path, flags, mode) }
    public static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer!, _ count: Int) -> Int { systemRead(descriptor, buffer, count) }
    public static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer!, _ count: Int) -> Int { systemWrite(descriptor, buffer, count) }
    public static func rename(_ old: String, _ new: String) -> Int32 { systemRename(old, new) }
    public static func mkdir(_ path: String, _ mode: mode_t) -> Int32 { systemMkdir(path, mode) }
    public static func poll(_ descriptors: UnsafeMutablePointer<pollfd>!, _ count: nfds_t, _ timeout: Int32) -> Int32 { systemPoll(descriptors, count, timeout) }
    public static func accept(_ descriptor: Int32) -> Int32 { systemAccept(descriptor, nil, nil) }
    /// Shuts down both directions, waking blocked readers and writers.
    @discardableResult public static func shutdown(_ descriptor: Int32) -> Int32 { systemShutdown(descriptor, Int32(SHUT_RDWR)) }

    /// Writes to a socket without raising SIGPIPE when the peer has gone: an error return
    /// instead. macOS sockets opt out with `SO_NOSIGPIPE` (see `disableSIGPIPE(on:)`); Linux
    /// has no such option, only the per-call `MSG_NOSIGNAL`.
    public static func send(_ descriptor: Int32, _ buffer: UnsafeRawPointer!, _ count: Int) -> Int {
        #if os(Linux)
        systemSend(descriptor, buffer, count, Int32(MSG_NOSIGNAL))
        #else
        systemSend(descriptor, buffer, count, 0)
        #endif
    }

    /// Makes writes to this socket fail with EPIPE instead of raising SIGPIPE, where the
    /// platform supports it per socket. On Linux, write with `send(_:_:_:)` instead.
    public static func disableSIGPIPE(on descriptor: Int32) {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
}

// At file scope these names resolve to the C library, not to `POSIX`'s members.
private func systemClose(_ descriptor: Int32) -> Int32 { close(descriptor) }
private func systemOpen(_ path: String, _ flags: Int32) -> Int32 { open(path, flags) }
private func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 { open(path, flags, mode) }
private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer!, _ count: Int) -> Int { read(descriptor, buffer, count) }
private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer!, _ count: Int) -> Int { write(descriptor, buffer, count) }
private func systemRename(_ old: String, _ new: String) -> Int32 { rename(old, new) }
private func systemMkdir(_ path: String, _ mode: mode_t) -> Int32 { mkdir(path, mode) }
private func systemPoll(_ descriptors: UnsafeMutablePointer<pollfd>!, _ count: nfds_t, _ timeout: Int32) -> Int32 { poll(descriptors, count, timeout) }
private func systemAccept(_ descriptor: Int32, _ address: UnsafeMutablePointer<sockaddr>!, _ length: UnsafeMutablePointer<socklen_t>!) -> Int32 { accept(descriptor, address, length) }
private func systemShutdown(_ descriptor: Int32, _ how: Int32) -> Int32 { shutdown(descriptor, how) }
private func systemSend(_ descriptor: Int32, _ buffer: UnsafeRawPointer!, _ count: Int, _ flags: Int32) -> Int { send(descriptor, buffer, count, flags) }
