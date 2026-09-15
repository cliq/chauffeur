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
    public init(root: URL = Paths.applicationSupport) throws {
        self.root = URL(fileURLWithPath: Paths.canonical(root.path))
        for directory in ["preset-sets", "projects", "runtime", "runtime/snapshots", "worktrees"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    public func reload() -> StoreSnapshot {
        var result = StoreSnapshot()
        var errors: [ChauffeurError] = []
        func read<T: Record>(_ type: T.Type, _ url: URL, into records: inout [Stored<T>]) {
            do {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ChauffeurError("invalid_record", "Record must be a regular file") }
                let data = try Data(contentsOf: url)
                let value = try JSONCoding.decode(type, from: data)
                try value.validate()
                guard !records.contains(where: { $0.value.id == value.id }) else { throw ChauffeurError("duplicate_id", "Duplicate record UUID") }
                records.append(Stored(value: value, path: url.path, version: JSONCoding.digest(data)))
            } catch {
                errors.append(ChauffeurError("invalid_record", "Cannot load \(type): \(Self.safeError(error))", path: url.path))
            }
        }
        for directory in directories(root.appendingPathComponent("preset-sets"), errors: &errors) {
            let metadata = directory.appendingPathComponent("preset-set.json")
            read(PresetSet.self, metadata, into: &result.presetSets)
            for file in files(directory.appendingPathComponent("presets"), errors: &errors) {
                read(AgentPreset.self, file, into: &result.presets)
            }
        }
        for directory in directories(root.appendingPathComponent("projects"), errors: &errors) {
            read(Project.self, directory.appendingPathComponent("project.json"), into: &result.projects)
            for file in files(directory.appendingPathComponent("sessions"), errors: &errors) { read(Session.self, file, into: &result.sessions) }
            for file in files(directory.appendingPathComponent("worktrees"), errors: &errors) { read(Worktree.self, file, into: &result.worktrees) }
            let window = directory.appendingPathComponent("window-state.json")
            if manager.fileExists(atPath: window.path) { read(WindowState.self, window, into: &result.windows) }
        }
        // Preserve unresolved references rather than selecting another set.
        for project in result.projects where !result.presetSets.contains(where: { $0.value.id == project.value.presetSetID }) {
            errors.append(ChauffeurError("unresolved_preset_set", "Project's preset set is missing", path: project.path))
        }
        result.projects.sort { $0.value.lastOpenedAt > $1.value.lastOpenedAt }
        result.errors = errors
        snapshot = result
        return result
    }

    public func current() -> StoreSnapshot { snapshot }

    @discardableResult public func save(_ value: PresetSet, expectedVersion: String? = nil) throws -> Stored<PresetSet> {
        let existing = snapshot.presetSets.first { $0.value.id == value.id }
        let url = existing.map { URL(fileURLWithPath: $0.path) } ?? uniqueDirectory(parent: root.appendingPathComponent("preset-sets"), name: value.name).appendingPathComponent("preset-set.json")
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.presetSets.removeAll { $0.value.id == value.id }; snapshot.presetSets.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: AgentPreset, expectedVersion: String? = nil) throws -> Stored<AgentPreset> {
        guard let set = snapshot.presetSets.first(where: { $0.value.id == value.setID }) else { throw ChauffeurError("missing_set", "Preset set is unresolved") }
        let existing = snapshot.presets.first { $0.value.id == value.id }
        let parent = URL(fileURLWithPath: set.path).deletingLastPathComponent().appendingPathComponent("presets")
        let url = existing.map { URL(fileURLWithPath: $0.path) } ?? uniqueFile(parent: parent, name: value.name)
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.presets.removeAll { $0.value.id == value.id }; snapshot.presets.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: Project, expectedVersion: String? = nil) throws -> Stored<Project> {
        let existing = snapshot.projects.first { $0.value.id == value.id }
        let url = existing.map { URL(fileURLWithPath: $0.path) } ?? uniqueDirectory(parent: root.appendingPathComponent("projects"), name: value.name).appendingPathComponent("project.json")
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.projects.removeAll { $0.value.id == value.id }; snapshot.projects.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: Session, expectedVersion: String? = nil) throws -> Stored<Session> {
        let url = try projectDirectory(value.projectID).appendingPathComponent("sessions/\(value.id.uuidString).json")
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.sessions.removeAll { $0.value.id == value.id }; snapshot.sessions.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: Worktree, expectedVersion: String? = nil) throws -> Stored<Worktree> {
        let url = try projectDirectory(value.projectID).appendingPathComponent("worktrees/\(value.id.uuidString).json")
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.worktrees.removeAll { $0.value.id == value.id }; snapshot.worktrees.append(saved)
        return saved
    }
    @discardableResult public func save(_ value: WindowState, expectedVersion: String? = nil) throws -> Stored<WindowState> {
        let url = try projectDirectory(value.id).appendingPathComponent("window-state.json")
        let saved = try write(value, at: url, expectedVersion: expectedVersion)
        snapshot.windows.removeAll { $0.value.id == value.id }; snapshot.windows.append(saved)
        return saved
    }
    public func projectDirectory(_ id: UUID) throws -> URL {
        guard let record = snapshot.projects.first(where: { $0.value.id == id }) else { throw ChauffeurError("missing_project", "Project is missing. Restore or reopen its directory") }
        return URL(fileURLWithPath: record.path).deletingLastPathComponent()
    }
    private func write<T: Record>(_ value: T, at url: URL, expectedVersion: String?) throws -> Stored<T> {
        try value.validate()
        if manager.fileExists(atPath: url.path) {
            guard let expectedVersion, let existing = try? Data(contentsOf: url), JSONCoding.digest(existing) == expectedVersion else {
                throw ChauffeurError("edit_conflict", "File changed. Reload before saving", path: url.path)
            }
        } else if expectedVersion != nil { throw ChauffeurError("edit_conflict", "File was removed. Reload before saving", path: url.path) }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONCoding.encode(value)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return Stored(value: value, path: url.path, version: JSONCoding.digest(data))
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
        guard manager.fileExists(atPath: url.path) else { return [] }
        do { return try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).sorted { $0.path < $1.path } }
        catch { errors.append(ChauffeurError("unreadable_directory", "Cannot read directory", path: url.path)); return [] }
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
