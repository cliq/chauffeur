import Foundation
import CoreServices

struct MetadataChanges: Sendable {
    var paths = Set<String>()
    var rescan = false
    var restart = false
    var isEmpty: Bool { paths.isEmpty && !rescan && !restart }
}

/// FSEvents owns a retained buffer, not this object. That keeps queued callbacks
/// safe during stream teardown without creating a stream/owner retain cycle.
final class MetadataWatcher: @unchecked Sendable {
    private final class Buffer: @unchecked Sendable {
        let root: String
        private let lock = NSLock()
        private var changes = MetadataChanges()
        init(root: String) { self.root = root }
        func collect(path suppliedPath: String, flags: FSEventStreamEventFlags) {
            // FSEvents supplies canonical paths. Foundation standardization can
            // turn existing /private/tmp paths into /tmp while leaving removed
            // paths unchanged, which would discard the actual replacement event.
            let path = suppliedPath.count > 1 && suppliedPath.hasSuffix("/") ? String(suppliedPath.dropLast()) : suppliedPath
            let lost = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped) != 0
            let movedRoot = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount) != 0
            let metadataPath = path == root || ["base-agent-presets", "preset-sets", "projects"].contains { path == root + "/" + $0 || path.hasPrefix(root + "/" + $0 + "/") }
            guard lost || movedRoot || metadataPath else { return }
            lock.withLock {
                if lost || movedRoot || flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    changes.rescan = true
                } else { changes.paths.insert(path) }
                if movedRoot { changes.restart = true }
                // Bound memory even if the consumer is temporarily busy.
                if changes.paths.count > 4096 { changes.paths.removeAll(); changes.rescan = true }
            }
        }
        func drain() -> MetadataChanges {
            lock.withLock { let result = changes; changes = MetadataChanges(); return result }
        }
    }
    private let buffer: Buffer
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.chauffeur.metadata-events", qos: .utility)

    init(root: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { throw Self.unavailable(root) }
        buffer = Buffer(root: root.path)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(buffer).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Buffer>.fromOpaque(pointer).retain(); return pointer
            },
            release: { pointer in if let pointer { Unmanaged<Buffer>.fromOpaque(pointer).release() } }, copyDescription: nil)
        guard let created = FSEventStreamCreate(nil, { _, context, count, eventPaths, flags, _ in
            guard let context else { return }
            let buffer = Unmanaged<Buffer>.fromOpaque(context).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count { buffer.collect(path: String(cString: paths[index]), flags: flags[index]) }
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)) else { throw Self.unavailable(root) }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created); stream = nil
            throw Self.unavailable(root)
        }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
    func drain() -> MetadataChanges { buffer.drain() }
    private static func unavailable(_ root: URL) -> ChauffeurError {
        ChauffeurError("metadata_watcher", "File notifications are unavailable. Metadata will be checked periodically until watching can resume", path: root.path)
    }
}
