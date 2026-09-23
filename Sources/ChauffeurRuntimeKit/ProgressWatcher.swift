import Foundation
import CoreServices
import ChauffeurCore

/// Watches the containing directory so atomic replacement does not orphan the watch.
/// FSEvents coalesces writes; only a valid document whose milestones changed wakes
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
}
