import Foundation
import CryptoKit

public struct Stored<Value: Record>: Codable, Sendable {
    public var value: Value
    public var path: String
    public var version: String
}

public struct StoreSnapshot: Codable, Sendable {
    public var presetSets: [Stored<PresetSet>] = []
    public var presets: [Stored<AgentPreset>] = []
    public var projects: [Stored<Project>] = []
    public var sessions: [Stored<Session>] = []
    public var worktrees: [Stored<Worktree>] = []
    public var windows: [Stored<WindowState>] = []
    public var errors: [ChauffeurError] = []
    public init() {}
}

public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601; return encoder
    }
    public static func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
    public static func encode<T: Encodable>(_ value: T) throws -> Data { try encoder().encode(value) }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T { try decoder().decode(type, from: data) }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Runtime-owned single writer. Version is the hash of the bytes read, so edits
/// made outside Chauffeur cannot be silently overwritten by a stale window.
public actor FileStore {
    public let root: URL
    private let manager = FileManager.default
    private var snapshot = StoreSnapshot()
    private var watcher: MetadataWatcher?
    private var watcherError: ChauffeurError?
    private var lastWatcherRetry = ContinuousClock.now
    private var loaded = false
    private var recordCache: [String: Any] = [:]
    private var directoryCache: [String: Result<[URL], ChauffeurError>] = [:]
    private var localChanges = Set<String>()
    // Internal counters allow tests to verify actual I/O, not just returned values.
    struct ReadCounts: Equatable, Sendable { var records = 0; var directories = 0; var scans = 0 }
    private var readCounts = ReadCounts()
    func ioCounts() -> ReadCounts { readCounts }
    public init(root: URL = Paths.applicationSupport) throws {
        self.root = URL(fileURLWithPath: Paths.canonical(root.path))
        for directory in ["preset-sets", "projects", "runtime", "runtime/snapshots", "worktrees"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Begin observing before the initial scan; changes during that scan
        // remain queued and will invalidate its cache on the next refresh.
        do { watcher = try MetadataWatcher(root: self.root) }
        catch { watcherError = error as? ChauffeurError }
    }

    /// Explicit refresh for preflight and writes. Does not rely on event delivery
    /// latency when deciding whether an externally edited reference is current.
    public func reload() -> StoreSnapshot {
        let changes = watcher?.drain()
        if changes?.restart == true { restartWatcher() }
        recordCache.removeAll(); directoryCache.removeAll(); localChanges.removeAll()
        return scan()
    }

    /// Ordinary runtime observations do no filesystem I/O while idle.
    public func refresh() -> StoreSnapshot {
        refresh(changes: watcher?.drain() ?? MetadataChanges())
    }
    func refresh(changes observed: MetadataChanges) -> StoreSnapshot {
        var changes = observed
        if changes.restart || (watcher == nil && ContinuousClock.now - lastWatcherRetry >= .seconds(5)) {
            restartWatcher(); changes.rescan = true
        }
        changes.paths.formUnion(localChanges); localChanges.removeAll()
        guard loaded && !changes.rescan else {
            recordCache.removeAll(); directoryCache.removeAll()
            return scan()
        }
        guard !changes.isEmpty else { return snapshot }
        for path in changes.paths { invalidate(path) }
        return scan()
    }

    private func restartWatcher() {
        watcher = nil; lastWatcherRetry = .now
        do { watcher = try MetadataWatcher(root: root); watcherError = nil }
        catch { watcherError = error as? ChauffeurError }
    }
    private func invalidate(_ path: String) {
        recordCache = recordCache.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        directoryCache = directoryCache.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        // A new child may have created several missing ancestors. Refresh their
        // entry lists while keeping unrelated records and subtree lists cached.
        var ancestor = URL(fileURLWithPath: path).deletingLastPathComponent()
        while ancestor.path == root.path || ancestor.path.hasPrefix(root.path + "/") {
            directoryCache.removeValue(forKey: ancestor.path)
            ancestor.deleteLastPathComponent()
        }
    }
    private func readRecord<T: Record>(_ type: T.Type, _ url: URL) throws -> Stored<T> {
        if let cached = recordCache[url.path] as? Result<Stored<T>, ChauffeurError> { return try cached.get() }
        readCounts.records += 1
        let result: Result<Stored<T>, ChauffeurError>
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ChauffeurError("invalid_record", "Record must be a regular file") }
            let data = try Data(contentsOf: url)
            let value = try JSONCoding.decode(type, from: data); try value.validate()
            result = .success(Stored(value: value, path: url.path, version: JSONCoding.digest(data)))
        } catch { result = .failure(ChauffeurError("invalid_record", "Cannot load \(type): \(Self.safeError(error))", path: url.path)) }
        recordCache[url.path] = result
        return try result.get()
    }
    private func scan() -> StoreSnapshot {
        readCounts.scans += 1
        var result = StoreSnapshot()
        var errors: [ChauffeurError] = []
        if let watcherError { errors.append(watcherError) }
        var visitedRecords = Set<String>()
        @discardableResult func read<T: Record>(_ type: T.Type, _ url: URL, into records: inout [Stored<T>], check: (T) throws -> Void = { _ in }) -> T? {
            visitedRecords.insert(url.path)
            do {
                let stored = try readRecord(type, url)
                let value = stored.value
                try check(value)
                guard !records.contains(where: { $0.value.id == value.id }) else { throw ChauffeurError("duplicate_id", "Duplicate record UUID") }
                records.append(stored)
                return value
            } catch {
                errors.append((error as? ChauffeurError).flatMap { $0.path == url.path ? $0 : nil } ?? ChauffeurError("invalid_record", "Cannot load \(type): \(Self.safeError(error))", path: url.path))
                return nil
            }
        }
        for directory in directories(root.appendingPathComponent("preset-sets"), errors: &errors) {
            let metadata = directory.appendingPathComponent("preset-set.json")
            let set = read(PresetSet.self, metadata, into: &result.presetSets)
            for file in files(directory.appendingPathComponent("presets"), errors: &errors) {
                read(AgentPreset.self, file, into: &result.presets) { value in
                    try Validation.require(value.setID == set?.id, "Preset does not belong to its containing preset set")
                }
            }
        }
        for directory in directories(root.appendingPathComponent("projects"), errors: &errors) {
            let project = read(Project.self, directory.appendingPathComponent("project.json"), into: &result.projects)
            for file in files(directory.appendingPathComponent("sessions"), errors: &errors) {
                read(Session.self, file, into: &result.sessions) { value in
                    try Validation.require(value.projectID == project?.id, "Session does not belong to its containing project")
                }
            }
            for file in files(directory.appendingPathComponent("worktrees"), errors: &errors) {
                read(Worktree.self, file, into: &result.worktrees) { value in
                    try Validation.require(value.projectID == project?.id, "Worktree does not belong to its containing project")
                }
            }
            let window = directory.appendingPathComponent("window-state.json")
            if children(directory, errors: &errors).contains(window) {
                read(WindowState.self, window, into: &result.windows) { value in
                    try Validation.require(value.id == project?.id, "Window does not belong to its containing project")
                }
            }
        }
        errors += StoreReferences.errors(in: result)
        result.projects.sort { $0.value.lastOpenedAt > $1.value.lastOpenedAt }
        result.errors = errors
        snapshot = result
        recordCache = recordCache.filter { visitedRecords.contains($0.key) }
        loaded = true
        return result
    }

    public func current() -> StoreSnapshot { snapshot }

    @discardableResult public func save(_ value: PresetSet, expectedVersion: String? = nil) throws -> Stored<PresetSet> {
        _ = reload()
        let existing = snapshot.presetSets.first { $0.value.id == value.id }
        let url = existing.map { URL(fileURLWithPath: $0.path) } ?? uniqueDirectory(parent: root.appendingPathComponent("preset-sets"), name: value.name).appendingPathComponent("preset-set.json")
        if let id = value.defaultPresetID {
            try reference(snapshot.presets.contains { $0.value.id == id && $0.value.setID == value.id }, "Choose a default preset from this set", at: url)
        }
        var value = value
        if let existing {
            let changed = existing.value.name != value.name || existing.value.defaultPresetID != value.defaultPresetID || existing.value.archived != value.archived
            value.revision = changed ? try nextRevision(existing.value.revision) : existing.value.revision
        }
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.presetSets.removeAll { $0.value.id == value.id }; snapshot.presetSets.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: AgentPreset, expectedVersion: String? = nil) throws -> Stored<AgentPreset> {
        _ = reload()
        guard let set = snapshot.presetSets.first(where: { $0.value.id == value.setID }) else { throw ChauffeurError("missing_set", "Preset set is unresolved") }
        let existing = snapshot.presets.first { $0.value.id == value.id }
        let parent = URL(fileURLWithPath: set.path).deletingLastPathComponent().appendingPathComponent("presets")
        let url = existing.map { URL(fileURLWithPath: $0.path) } ?? uniqueFile(parent: parent, name: value.name)
        try reference(existing == nil || existing?.value.setID == value.setID, "A preset cannot move between sets. Create a new preset instead", at: url)
        try value.validate()
        try checkVersion(at: url, expectedVersion: expectedVersion)
        if existing?.value != value {
            // Advance the parent first: a failed child write can leave a skipped
            // revision, but a changed preset never retains an old revision.
            var revised = set.value; revised.revision = try nextRevision(revised.revision)
            let savedSet = try write(revised, at: URL(fileURLWithPath: set.path), expectedVersion: set.version)
            snapshot.presetSets.removeAll { $0.value.id == revised.id }; snapshot.presetSets.append(savedSet)
        }
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.presets.removeAll { $0.value.id == value.id }; snapshot.presets.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: Project, expectedVersion: String? = nil) throws -> Stored<Project> {
        _ = reload()
        let existing = snapshot.projects.first { $0.value.id == value.id }
        let url = existing.map { URL(fileURLWithPath: $0.path) } ?? uniqueDirectory(parent: root.appendingPathComponent("projects"), name: value.name).appendingPathComponent("project.json")
        var value = value
        try reference(snapshot.presetSets.contains { $0.value.id == value.presetSetID } || existing?.value.presetSetID == value.presetSetID, "Choose an existing preset set", at: url)
        if let previous = existing?.value, previous.presetSetID != value.presetSetID, value.lastPresetID == previous.lastPresetID { value.lastPresetID = nil }
        if let id = value.lastPresetID {
            try reference(snapshot.presets.contains { $0.value.id == id && $0.value.setID == value.presetSetID } || (existing?.value.lastPresetID == id && existing?.value.presetSetID == value.presetSetID), "Last-used preset must belong to the project's set", at: url)
        }
        if let previous = existing?.value {
            let removedGroups = Set(previous.groups.map(\.id)).subtracting(value.groups.map(\.id))
            let removedFolders = Set(previous.folders.map(\.id)).subtracting(value.folders.map(\.id))
            try reference(!snapshot.sessions.contains { $0.value.projectID == value.id && removedGroups.contains($0.value.groupID) }, "Archive groups with session history instead of removing them", at: url)
            try reference(!snapshot.sessions.contains { $0.value.projectID == value.id && removedFolders.contains($0.value.folderID) } && !snapshot.worktrees.contains { $0.value.projectID == value.id && removedFolders.contains($0.value.folderID) }, "Unregister folders with session or worktree history instead of removing them", at: url)
        }
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.projects.removeAll { $0.value.id == value.id }; snapshot.projects.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: Session, expectedVersion: String? = nil) throws -> Stored<Session> {
        _ = reload()
        let url = try projectDirectory(value.projectID).appendingPathComponent("sessions/\(value.id.uuidString).json")
        if let existing = snapshot.sessions.first(where: { $0.value.id == value.id })?.value {
            try reference(existing.projectID == value.projectID && existing.groupID == value.groupID && existing.parentID == value.parentID, "Session membership and parent cannot change", at: url)
        } else {
            let project = snapshot.projects.first { $0.value.id == value.projectID }!.value
            try reference(project.groups.contains { $0.id == value.groupID } && project.folders.contains { $0.id == value.folderID }, "Session must reference a group and folder in its project", at: url)
            if let id = value.worktreeID {
                try reference(snapshot.worktrees.contains { $0.value.id == id && $0.value.projectID == value.projectID && $0.value.folderID == value.folderID }, "Session worktree must belong to its project and folder", at: url)
            }
        }
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.sessions.removeAll { $0.value.id == value.id }; snapshot.sessions.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: Worktree, expectedVersion: String? = nil) throws -> Stored<Worktree> {
        _ = reload()
        let url = try projectDirectory(value.projectID).appendingPathComponent("worktrees/\(value.id.uuidString).json")
        try reference(snapshot.projects.contains { $0.value.id == value.projectID && $0.value.folders.contains { $0.id == value.folderID } }, "Worktree must reference a folder in its project", at: url)
        if let existing = snapshot.worktrees.first(where: { $0.value.id == value.id })?.value {
            let upgradingIdentity = existing.repositoryIdentityVersion == nil && value.repositoryIdentityVersion == 1
                && value.gitIdentity != nil && (existing.gitIdentity == value.gitIdentity
                    || (existing.gitIdentity == nil && existing.path == value.path))
            try reference(existing.projectID == value.projectID && existing.folderID == value.folderID
                && (existing.repositoryID == value.repositoryID || upgradingIdentity)
                && (existing.repositoryIdentityVersion == value.repositoryIdentityVersion || upgradingIdentity), "Worktree project, folder and repository cannot change", at: url)
        }
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.worktrees.removeAll { $0.value.id == value.id }; snapshot.worktrees.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: WindowState, expectedVersion: String? = nil) throws -> Stored<WindowState> {
        _ = reload()
        let url = try projectDirectory(value.id).appendingPathComponent("window-state.json")
        if let group = value.selectedGroupID {
            try reference(snapshot.projects.contains { $0.value.id == value.id && $0.value.groups.contains { $0.id == group } }, "Select a group in this window's project", at: url)
        }
        // Missing session files may still be retained by the runtime ledger;
        // diagnose those on read, but never accept a known foreign session.
        try reference(!snapshot.sessions.contains { value.tabs.contains($0.value.id) && $0.value.projectID != value.id }, "Window tabs must belong to this project", at: url)
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.windows.removeAll { $0.value.id == value.id }; snapshot.windows.append(saved)
        return saved
    }
    /// Patch only this preference against current metadata. A launch which
    /// finishes after the project changed sets must not restore the old choice.
    public func rememberPreset(_ presetID: UUID, projectID: UUID, setID: UUID) throws {
        _ = reload()
        guard let stored = snapshot.projects.first(where: { $0.value.id == projectID }), stored.value.presetSetID == setID,
              snapshot.presets.contains(where: { $0.value.id == presetID && $0.value.setID == setID && !$0.value.archived }),
              stored.value.lastPresetID != presetID else { return }
        var value = stored.value; value.lastPresetID = presetID
        let saved = try write(value, at: URL(fileURLWithPath: stored.path), expectedVersion: stored.version)
        snapshot.projects.removeAll { $0.value.id == projectID }; snapshot.projects.append(saved)
    }
    public func projectDirectory(_ id: UUID) throws -> URL {
        guard let record = snapshot.projects.first(where: { $0.value.id == id }) else { throw ChauffeurError("missing_project", "Project is missing. Restore or reopen its directory") }
        return URL(fileURLWithPath: record.path).deletingLastPathComponent()
    }
    private func write<T: Record>(_ value: T, at url: URL, expectedVersion: String?) throws -> Stored<T> {
        try value.validate()
        try checkVersion(at: url, expectedVersion: expectedVersion)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONCoding.encode(value)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        localChanges.insert(url.path)
        return Stored(value: value, path: url.path, version: JSONCoding.digest(data))
    }
    private func checkVersion(at url: URL, expectedVersion: String?) throws {
        if manager.fileExists(atPath: url.path) {
            guard let expectedVersion, let existing = try? Data(contentsOf: url), JSONCoding.digest(existing) == expectedVersion else {
                throw ChauffeurError("edit_conflict", "File changed. Reload before saving", path: url.path)
            }
        } else if expectedVersion != nil { throw ChauffeurError("edit_conflict", "File was removed. Reload before saving", path: url.path) }
    }
    private func nextRevision(_ revision: Int) throws -> Int {
        try Validation.require(revision < Int.max, "Preset set revision has reached its maximum")
        return revision + 1
    }
    private func reference(_ valid: Bool, _ message: String, at url: URL) throws {
        guard valid else { throw ChauffeurError("unresolved_reference", message, path: url.path) }
    }
    private func uniqueDirectory(parent: URL, name: String) -> URL {
        let base = Paths.slug(name); var suffix = 1
        while true {
            let candidate = parent.appendingPathComponent(suffix == 1 ? base : "\(base)-\(suffix)")
            if !manager.fileExists(atPath: candidate.path) { return candidate }; suffix += 1
        }
    }
    private func uniqueFile(parent: URL, name: String) -> URL {
        let base = Paths.slug(name); var suffix = 1
        while true {
            let candidate = parent.appendingPathComponent((suffix == 1 ? base : "\(base)-\(suffix)") + ".json")
            if !manager.fileExists(atPath: candidate.path) { return candidate }; suffix += 1
        }
    }
    private func children(_ url: URL, errors: inout [ChauffeurError]) -> [URL] {
        if let cached = directoryCache[url.path] {
            switch cached { case .success(let children): return children; case .failure(let error): errors.append(error); return [] }
        }
        readCounts.directories += 1
        let result: Result<[URL], ChauffeurError>
        do {
            guard manager.fileExists(atPath: url.path) else { directoryCache[url.path] = .success([]); return [] }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true && values.isSymbolicLink != true else { throw ChauffeurError("invalid_record", "Metadata directory must not be a symlink") }
            result = .success(try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).sorted { $0.path < $1.path })
        }
        catch { result = .failure(ChauffeurError("unreadable_directory", "Cannot read directory", path: url.path)) }
        directoryCache[url.path] = result
        switch result { case .success(let children): return children; case .failure(let error): errors.append(error); return [] }
    }
    private func directories(_ url: URL, errors: inout [ChauffeurError]) -> [URL] {
        children(url, errors: &errors).filter { child in
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }
    private func files(_ url: URL, errors: inout [ChauffeurError]) -> [URL] { children(url, errors: &errors).filter { $0.pathExtension == "json" } }
    private static func safeError(_ error: Error) -> String {
        // Decoding errors can embed corrupt file contents. Never copy them to UI/logs.
        if error is DecodingError { return "Invalid JSON or record schema" }
        return (error as? ChauffeurError)?.message ?? "File could not be read"
    }
}

public enum RepositoryDiscovery {
    public struct Result: Codable, Sendable {
        public var folders: [ProjectFolder] = []
        public var errors: [ChauffeurError] = []
        public var cancelled = false
    }
    /// Run off the main actor. Never follows directory symlinks or enters .git.
    public static func scan(parent: String, isCancelled: @Sendable () -> Bool = { false }) -> Result {
        var result = Result(); var pending = [URL(fileURLWithPath: parent)]; var seen = Set<String>()
        while let directory = pending.popLast() {
            if isCancelled() { result.cancelled = true; break }
            let canonical = Paths.canonical(directory.path)
            guard seen.insert(canonical).inserted else { continue }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                result.folders.append(ProjectFolder(path: directory.path))
            }
            do {
                let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                for child in children where child.lastPathComponent != ".git" {
                    let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory == true && values.isSymbolicLink != true { pending.append(child) }
                }
            } catch { result.errors.append(ChauffeurError("unreadable_directory", "Cannot inspect this location", path: directory.path)) }
        }
        result.folders.sort { $0.canonicalPath < $1.canonicalPath }
        return result
    }
}
