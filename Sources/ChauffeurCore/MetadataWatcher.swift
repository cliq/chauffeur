import Foundation
#if canImport(CoreServices)
import CoreServices
#else
import Glibc
#endif

struct MetadataChanges: Sendable {
    var paths = Set<String>()
    var rescan = false
    var restart = false
    var isEmpty: Bool { paths.isEmpty && !rescan && !restart }
}

#if canImport(CoreServices)
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
#else
/// inotify watches single directories, so each directory of the metadata trees gets its own
/// watch, added as directories appear. Events wait in the kernel's queue until the store
/// drains them, so no thread is needed.
final class MetadataWatcher: @unchecked Sendable {
    private static let metadataDirectories = ["base-agent-presets", "preset-sets", "projects"]
    private let root: String
    private let inotify: Inotify
    private let rootWatch: Int32
    private let lock = NSLock()
    private var directories: [Int32: String] = [:]
    private var changes = MetadataChanges()
    /// Set when the user's watch limit (`fs.inotify.max_user_watches`) refused a directory,
    /// whose changes would go unnoticed. The store then drops this watcher and rescans
    /// periodically instead.
    private var exhausted = false

    init(root: URL) throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              let inotify = Inotify(), let rootWatch = inotify.watch(root.path) else { throw Self.unavailable(root) }
        self.root = root.path
        self.inotify = inotify
        self.rootWatch = rootWatch
        directories[rootWatch] = root.path
        watchMetadata()
        guard !exhausted else { throw Self.unavailable(root) }
    }

    func drain() -> MetadataChanges {
        lock.withLock {
            for event in inotify.read() { collect(event) }
            if exhausted { changes.rescan = true; changes.restart = true }
            let result = changes
            changes = MetadataChanges()
            return result
        }
    }

    private func collect(_ event: Inotify.Event) {
        if event.contains(Int32(IN_Q_OVERFLOW)) {
            // Directories created meanwhile have no watch yet; adding existing ones again is harmless.
            changes.rescan = true
            watchMetadata()
            return
        }
        guard let directory = directories[event.watch] else { return }
        if event.contains(Int32(IN_IGNORED)) { directories.removeValue(forKey: event.watch); return }
        if event.watch == rootWatch {
            if event.contains(Int32(IN_DELETE_SELF | IN_MOVE_SELF)) { changes.rescan = true; changes.restart = true; return }
            // The root itself holds runtime state too; only the metadata folders matter.
            guard Self.metadataDirectories.contains(event.name) else { return }
        }
        let path = event.name.isEmpty ? directory : directory + "/" + event.name
        // A new directory may have gained entries before its watch existed; recording its
        // path makes the store reread the whole subtree.
        if event.contains(Int32(IN_ISDIR)), event.contains(Int32(IN_CREATE | IN_MOVED_TO)) { watchTree(path) }
        changes.paths.insert(path)
        // Bound memory even if the consumer is temporarily busy.
        if changes.paths.count > 4096 { changes.paths.removeAll(); changes.rescan = true }
    }

    private func watchMetadata() {
        for name in Self.metadataDirectories { watchTree(root + "/" + name) }
    }

    /// Watching a directory again returns its existing watch, now under this path.
    private func watchTree(_ path: String) {
        guard let watch = inotify.watch(path) else {
            // Missing directories are watched once they appear.
            if errno == ENOSPC { exhausted = true }
            return
        }
        directories[watch] = path
        let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        // Not following symbolic links, like the watches themselves.
        for child in children where (try? FileManager.default.attributesOfItem(atPath: path + "/" + child))?[.type] as? FileAttributeType == .typeDirectory {
            watchTree(path + "/" + child)
        }
    }

    private static func unavailable(_ root: URL) -> ChauffeurError {
        ChauffeurError("metadata_watcher", "File notifications are unavailable. Metadata will be checked periodically until watching can resume", path: root.path)
    }
}
#endif
