import Foundation
#if canImport(CoreServices)
import CoreServices
#else
import Glibc
#endif
import ChauffeurCore

/// Watches the containing directory so atomic replacement does not orphan the watch, with
/// FSEvents on macOS and inotify on Linux. FSEvents coalesces writes; only a valid document whose milestones changed wakes
/// the agent, so frequent "now doing" updates do not re-enter a waiting coordinator.
final class ProgressWatcher: @unchecked Sendable {
    private final class Buffer: @unchecked Sendable {
        let path: String
        let changed: @Sendable () -> Void
        private var previous: ImplementationProgress?
        init(path: String, changed: @escaping @Sendable () -> Void) {
            self.path = path; self.changed = changed
            previous = try? ProgressFiles.read(jsonPath: path)
        }
        // Called only on the stream's serial dispatch queue after initialization.
        func refresh() {
            guard let current = try? ProgressFiles.read(jsonPath: path) else { return }
            defer { previous = current }
            guard let previous else { changed(); return }
            if current.changesMilestones(from: previous) { changed() }
        }
    }
    private let buffer: Buffer
    private let queue = DispatchQueue(label: "dev.chauffeur.progress-events", qos: .utility)
    #if canImport(CoreServices)
    private var stream: FSEventStreamRef?

    init?(path: String, changed: @escaping @Sendable () -> Void) {
        let url = URL(fileURLWithPath: Paths.canonical(path))
        buffer = Buffer(path: url.path, changed: changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(buffer).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Buffer>.fromOpaque(pointer).retain(); return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Buffer>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, { _, context, count, paths, flags, _ in
            guard let context else { return }
            let buffer = Unmanaged<Buffer>.fromOpaque(context).takeUnretainedValue()
            let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count {
                let rescan = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
                if rescan || String(cString: paths[index]) == buffer.path { buffer.refresh(); break }
            }
        }, &context, [url.deletingLastPathComponent().path] as CFArray,
           FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil
            return nil
        }
        // Catch writes between the baseline read and subscription establishment.
        let buffer = buffer
        queue.async { buffer.refresh() }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
    #else
    private let source: DispatchSourceRead

    /// The containing directory's watch, confined to the watcher's queue. Replacing or
    /// removing the directory ends the watch; it is renewed at the path, retrying each
    /// second until the directory exists again.
    private final class DirectoryWatch: @unchecked Sendable {
        let inotify: Inotify
        let directory: String
        let queue: DispatchQueue
        let buffer: Buffer
        var watch: Int32?
        init(inotify: Inotify, directory: String, queue: DispatchQueue, buffer: Buffer) {
            self.inotify = inotify; self.directory = directory; self.queue = queue; self.buffer = buffer
            watch = inotify.watch(directory)
        }
        func handleEvents(file: String) {
            let events = inotify.read()
            if events.contains(where: { $0.watch == watch && $0.contains(Int32(IN_DELETE_SELF | IN_MOVE_SELF | IN_IGNORED)) }) { renew() }
            if events.contains(where: { $0.name == file || $0.contains(Int32(IN_Q_OVERFLOW)) }) { buffer.refresh() }
        }
        private func renew() {
            if let watch { inotify.remove(watch) }
            watch = inotify.watch(directory)
            if watch == nil { queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.renew() } }
            else { buffer.refresh() }
        }
    }

    init?(path: String, changed: @escaping @Sendable () -> Void) {
        let url = URL(fileURLWithPath: Paths.canonical(path))
        buffer = Buffer(path: url.path, changed: changed)
        guard let inotify = Inotify() else { return nil }
        let watch = DirectoryWatch(inotify: inotify, directory: url.deletingLastPathComponent().path, queue: queue, buffer: buffer)
        guard watch.watch != nil else { return nil }
        let file = url.lastPathComponent
        source = DispatchSource.makeReadSource(fileDescriptor: inotify.descriptor, queue: queue)
        // The handler owns the watch and its inotify instance, so the descriptor closes only after cancellation.
        source.setEventHandler { watch.handleEvents(file: file) }
        source.resume()
        // Catch writes between the baseline read and the watch.
        let buffer = buffer
        queue.async { buffer.refresh() }
    }
    deinit { source.cancel() }
    #endif
}
