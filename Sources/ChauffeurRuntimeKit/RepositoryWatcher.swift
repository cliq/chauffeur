import Foundation
#if canImport(CoreServices)
import CoreServices
#endif

/// File changes under watched checkouts since the last drain.
struct RepositoryChanges: Sendable {
    /// Changed paths with the union of their event flags. Paths inside Git
    /// metadata are kept per file; working-tree files collapse to their
    /// directory, which is all the scanner needs to find the checkout.
    var paths: [String: RepositoryWatcher.Flags] = [:]
    /// Events were lost or too many arrived, so every repository must be read again.
    var rescan = false
}

#if canImport(CoreServices)
/// Watches checkouts and their Git metadata so the repository scan only runs
/// Git where something changed. FSEvents owns a retained buffer, not this
/// object, so queued callbacks stay safe during teardown.
final class RepositoryWatcher: @unchecked Sendable {
    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8
        /// A directory itself was created, removed or renamed.
        static let directoryChanged = Flags(rawValue: 1)
    }
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var changes = RepositoryChanges()
        private var delivered: UInt64
        init(startingAt eventID: UInt64) { delivered = eventID }
        /// The newest event handed to this buffer: a replacement stream starts
        /// here so events FSEvents had not delivered yet are not skipped.
        var lastDeliveredEventID: UInt64 { lock.withLock { delivered } }
        func advance(to eventID: UInt64) { lock.withLock { delivered = max(delivered, eventID) } }
        /// Bounds memory if a build writes many directories before the next drain.
        private static let limit = 20_000
        func collect(path suppliedPath: String, flags: FSEventStreamEventFlags) {
            if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { return }
            let path = suppliedPath.count > 1 && suppliedPath.hasSuffix("/") ? String(suppliedPath.dropLast()) : suppliedPath
            let lost = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
            let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            let structural = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
            let key: String
            var recorded: Flags = []
            if RepositoryChangeClassifier.isInsideGitMetadata(path) {
                guard !RepositoryChangeClassifier.isIgnorableMetadata(path) else { return }
                key = path
            } else if isDirectory {
                key = path
                if structural { recorded.insert(.directoryChanged) }
            } else {
                key = (path as NSString).deletingLastPathComponent
            }
            lock.withLock {
                if lost { changes.rescan = true; return }
                guard !changes.rescan else { return }
                changes.paths[key, default: []].formUnion(recorded)
                if changes.paths.count > Self.limit { changes.paths.removeAll(); changes.rescan = true }
            }
        }
        func drain() -> RepositoryChanges {
            lock.withLock { let result = changes; changes = RepositoryChanges(); return result }
        }
    }
    let paths: [String]
    private let buffer: Buffer
    var lastDeliveredEventID: UInt64 { buffer.lastDeliveredEventID }
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.chauffeur.repository-events", qos: .utility)

    /// The point in the event history a later watcher can start from, so
    /// nothing written while a scan ran goes unnoticed.
    static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    init?(paths: [String], since eventID: UInt64? = nil) {
        guard !paths.isEmpty else { return nil }
        self.paths = paths
        buffer = Buffer(startingAt: eventID ?? FSEventsGetCurrentEventId())
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(buffer).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Buffer>.fromOpaque(pointer).retain(); return pointer
            },
            release: { pointer in if let pointer { Unmanaged<Buffer>.fromOpaque(pointer).release() } }, copyDescription: nil)
        guard let created = FSEventStreamCreate(nil, { _, context, count, eventPaths, flags, ids in
            guard let context else { return }
            let buffer = Unmanaged<Buffer>.fromOpaque(context).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            for index in 0..<count {
                buffer.collect(path: String(cString: paths[index]), flags: flags[index])
                buffer.advance(to: ids[index])
            }
        }, &context, paths as CFArray, eventID.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
           // WatchRoot reports a watched folder moving with its parent, which
           // otherwise produces no event inside it.
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { return nil }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created); stream = nil
            return nil
        }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
    func drain() -> RepositoryChanges { buffer.drain() }
}
#else
/// Linux has no recursive file notifications cheap enough for whole checkouts,
/// so every scan reads every repository.
final class RepositoryWatcher: @unchecked Sendable {
    struct Flags: OptionSet, Sendable {
        let rawValue: UInt8
        static let directoryChanged = Flags(rawValue: 1)
    }
    let paths: [String] = []
    var lastDeliveredEventID: UInt64 { 0 }
    static func currentEventID() -> UInt64 { 0 }
    init?(paths: [String], since eventID: UInt64? = nil) { return nil }
    func drain() -> RepositoryChanges { RepositoryChanges(rescan: true) }
}
#endif

/// Decides which repositories and checkouts a set of file changes affects.
struct RepositoryChangeClassifier {
    struct Result: Equatable {
        /// Repositories whose worktree list, identities or branch counts may have changed.
        var repositories = Set<UUID>()
        /// Checkouts whose working-tree status may have changed.
        var checkouts = Set<String>()
        /// Unavailable source folders that changed and should be read again.
        var sources = Set<String>()
    }
    /// Checkout path → repository.
    let checkouts: [String: UUID]
    /// Git metadata directory → (repository, checkout path). A repository's
    /// shared directory maps to its main checkout, or to no checkout when bare.
    let gitDirectories: [String: (repository: UUID, checkout: String?)]
    /// Source folders whose last observation was not an available repository.
    let unavailableSources: Set<String>

    static func isInsideGitMetadata(_ path: String) -> Bool {
        path.hasSuffix("/.git") || path.contains("/.git/")
    }
    /// Metadata that changes without affecting the inventory or status: object
    /// storage, reflogs, and the lock files every Git command creates.
    static func isIgnorableMetadata(_ path: String) -> Bool {
        // Git refuses ref names ending in `.lock`, so these are always lock files.
        if path.hasSuffix(".lock") { return true }
        // Only names inside the metadata count: the folders above it, branch
        // names under refs/ and linked worktree names are chosen by the user.
        guard let metadata = path.range(of: "/.git/", options: .backwards) else { return false }
        var components = path[metadata.upperBound...].split(separator: "/")
        if components.count >= 2, components[0] == "worktrees" { components.removeFirst(2) }
        guard let first = components.first, first != "refs" else { return false }
        if ["objects", "logs", "lfs", "hooks", "rr-cache"].contains(first) { return true }
        return components.count == 1 && ["FETCH_HEAD", "ORIG_HEAD", "COMMIT_EDITMSG", "gc.pid", "gc.log"].contains(first)
    }

    func classify(_ changes: [String: RepositoryWatcher.Flags]) -> Result {
        var result = Result()
        for (path, flags) in changes { classify(path, flags: flags, into: &result) }
        return result
    }

    private func classify(_ path: String, flags: RepositoryWatcher.Flags, into result: inout Result) {
        var ancestor = path
        var relative: [String] = []
        while true {
            if let owner = gitDirectories[ancestor] {
                classifyMetadata(relative.reversed(), owner: owner, into: &result)
                return
            }
            if let repository = checkouts[ancestor] {
                // A checkout appearing, disappearing or being moved changes the
                // worktree list; anything else only changes its status.
                if relative.isEmpty && flags.contains(.directoryChanged) || relative == [".git"] { result.repositories.insert(repository) }
                result.checkouts.insert(ancestor)
            }
            if unavailableSources.contains(ancestor) { result.sources.insert(ancestor) }
            guard ancestor != "/", !ancestor.isEmpty else { return }
            relative.append((ancestor as NSString).lastPathComponent)
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }
    }

    private func classifyMetadata(_ relative: [String], owner: (repository: UUID, checkout: String?), into result: inout Result) {
        let first = relative.first
        if relative.count == 1, first == "index" {
            if let checkout = owner.checkout { result.checkouts.insert(checkout) }
            return
        }
        // A submodule's own commits and index only change its parent's status.
        if first == "modules" {
            if let checkout = owner.checkout { result.checkouts.insert(checkout) }
            return
        }
        // HEAD, branches, packed refs, worktree registrations and anything
        // unrecognised may change the inventory.
        result.repositories.insert(owner.repository)
    }
}
