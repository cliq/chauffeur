import Foundation
import Darwin
import ChauffeurCore

/// Publishes one bundled catalog and links it into CLI discovery directories.
/// Existing files and links owned by other tools are never replaced.
public actor SkillInstaller {
    private let skills: [CoordinationSkill]
    private let root: URL
    private var sourceFailure: ChauffeurError?

    public init(skills: [CoordinationSkill], root: URL) throws {
        let names = Set(skills.map(\.name))
        guard names.count == skills.count, !skills.isEmpty,
              skills.allSatisfy({ Set($0.dependencies).isSubset(of: names) }) else {
            throw ChauffeurError("skill_bundle", "The bundled skill catalog has invalid dependencies")
        }
        self.skills = skills.sorted { $0.name < $1.name }
        self.root = root.standardizedFileURL
    }

    /// Codex shares its user skills across profiles; Claude uses each team's home.
    public static func directories(teams: [PresetSet], home: String) -> [String] {
        Set([Paths.canonical(URL(fileURLWithPath: home).appendingPathComponent(".agents").path)]
            + teams.filter { !$0.archived }.map { $0.configurationDirectory(for: .claude, home: home) })
            .sorted()
    }

    public func publish() throws {
        do {
            try publishCatalog()
            sourceFailure = nil
        } catch {
            sourceFailure = error as? ChauffeurError ?? ChauffeurError("skill_unavailable", "Cannot publish the managed skill source")
            throw error
        }
    }

    private func publishCatalog() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = try Directory(path: root.path)
        let lock = try source.lock(".publish.lock")
        defer { flock(lock, LOCK_UN); close(lock) }
        let signature = skills.map { skill in
            skill.name + skill.version + skill.digest + skill.referenceDigests.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined()
        }.joined(separator: "\n")
        let version = "catalog-" + JSONCoding.digest(Data(signature.utf8))
        if let catalog = try source.child(version) {
            for skill in skills {
                guard let directory = try catalog.child(skill.name),
                      try directory.read("SKILL.md", limit: 65_536) == skill.document else {
                    throw conflict("The managed skill source changed. Its files are preserved.")
                }
                for (path, data) in skill.referenceFiles {
                    let parts = path.split(separator: "/").map(String.init)
                    guard let parent = try directory.descendant(parts.dropLast().joined(separator: "/")),
                          try parent.read(parts.last!, limit: 65_536) == data else {
                        throw conflict("The managed skill references changed. Their files are preserved.")
                    }
                }
            }
        } else {
            let stageName = ".stage-" + UUID().uuidString
            let stage = try source.child(stageName, create: true)!
            for skill in skills {
                let directory = try stage.child(skill.name, create: true)!
                try directory.write("SKILL.md", data: skill.document)
                for (path, data) in skill.referenceFiles { try directory.writePath(path, data: data) }
            }
            try source.move(stageName, to: version)
        }
        if let existing = try source.link("current") {
            guard existing.hasPrefix("catalog-"), !existing.contains("/") else {
                throw conflict("The managed skill source link belongs to another installation.")
            }
            if existing == version { return }
        }
        let stage = ".link-" + UUID().uuidString
        try source.symlink(stage, destination: version)
        defer { _ = unlinkat(source.fd, stage, 0) }
        guard renameat(source.fd, stage, source.fd, "current") == 0 else {
            throw ChauffeurError("skill_unavailable", "Cannot update the managed skill source")
        }
    }

    public func reconcile(directories: [String]) -> [SkillInstallation] {
        var results: [SkillInstallation] = []
        for directory in Set(directories).sorted() {
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let profile = try Directory(path: directory)
                let lock = try profile.lock(".chauffeur-skill.lock")
                defer { flock(lock, LOCK_UN); close(lock) }
                let destination = try profile.child("skills", create: true)!
                for skill in skills {
                    do {
                        if let link = try destination.link(skill.name) {
                            guard link == sourcePath(skill) else { throw conflict("An unrelated link already occupies this path. It was preserved.") }
                        } else {
                            try destination.symlink(skill.name, destination: sourcePath(skill))
                        }
                        results.append(status(directory: directory, skill: skill))
                    } catch { results.append(failure(error, directory: directory, skill: skill)) }
                }
            } catch {
                results += skills.map { failure(error, directory: directory, skill: $0) }
            }
        }
        return results
    }

    public func statuses(directory: String) -> [SkillInstallation] {
        skills.map { status(directory: directory, skill: $0) }
    }

    private func sourcePath(_ skill: CoordinationSkill) -> String {
        root.appendingPathComponent("current/" + skill.name).path
    }
    private func status(directory: String, skill: CoordinationSkill) -> SkillInstallation {
        if let sourceFailure { return failure(sourceFailure, directory: directory, skill: skill) }
        do {
            guard FileManager.default.fileExists(atPath: directory) else {
                return result(.notInstalled, directory: directory, skill: skill, message: "The skill directory has not been created yet.")
            }
            let profile = try Directory(path: directory)
            guard let destination = try profile.child("skills"), let link = try destination.link(skill.name) else {
                return result(.notInstalled, directory: directory, skill: skill, message: "The automatic skill link is missing. Refresh to repair it.")
            }
            guard link == sourcePath(skill) else { throw conflict("An unrelated link already occupies this path. It was preserved.") }
            guard FileManager.default.fileExists(atPath: sourcePath(skill) + "/SKILL.md") else {
                return result(.unavailable, directory: directory, skill: skill, message: "The managed source is unavailable. Restart Chauffeur to repair it.")
            }
            return result(.installed, directory: directory, skill: skill, message: "Linked automatically. Updates with Chauffeur.")
        } catch { return failure(error, directory: directory, skill: skill) }
    }
    private func failure(_ error: Error, directory: String, skill: CoordinationSkill) -> SkillInstallation {
        let error = error as? ChauffeurError ?? ChauffeurError("skill_unavailable", "Cannot access the skill directory")
        return result(error.code == "skill_conflict" ? .conflict : .unavailable, directory: directory, skill: skill, message: error.message)
    }
    private func result(_ state: SkillInstallation.State, directory: String, skill: CoordinationSkill, message: String) -> SkillInstallation {
        let path = URL(fileURLWithPath: directory).appendingPathComponent("skills/" + skill.name).path
        return SkillInstallation(name: skill.name, displayName: skill.displayName, summary: skill.summary,
            dependencies: skill.dependencies, state: state, path: path, bundledVersion: skill.version,
            installedVersion: state == .installed ? skill.version : nil, message: message,
            revision: JSONCoding.digest(Data((path + state.rawValue + skill.digest).utf8)))
    }
}

private func conflict(_ message: String) -> ChauffeurError { ChauffeurError("skill_conflict", message) }

/// Directory-relative operations pin parents and refuse symbolic links. No
/// recursive deletion, configuration edits, credential reads or CLI execution.
private final class Directory {
    let fd: Int32
    init(path: String) throws {
        fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ChauffeurError("skill_unavailable", "Cannot open the selected configuration directory") }
        do { try Self.checkDirectory(fd) } catch { close(fd); throw error }
    }
    private init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    private static func checkDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else {
            throw ChauffeurError("skill_unavailable", "The skill directory must be owned by the current user")
        }
    }
    func child(_ name: String, create: Bool = false) throws -> Directory? {
        if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw ChauffeurError("skill_unavailable", "Cannot create the skill directory") }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if child < 0 {
            if errno == ENOENT && !create { return nil }
            throw conflict("The skills path is inaccessible, a symbolic link, or not a directory. Its contents are preserved.")
        }
        do { try Self.checkDirectory(child); return Directory(fd: child) }
        catch { close(child); throw error }
    }
    /// nil means absent; an existing non-link is a conflict, including a directory.
    func link(_ name: String) throws -> String? {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw conflict("Cannot inspect the skill path")
        }
        guard info.st_mode & S_IFMT == S_IFLNK else { throw conflict("An existing file or directory occupies this skill path. It was preserved.") }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = readlinkat(fd, name, &bytes, bytes.count)
        guard count >= 0, count < bytes.count else { throw conflict("Cannot read the skill link") }
        return String(decoding: bytes.prefix(count), as: UTF8.self)
    }
    func symlink(_ name: String, destination: String) throws {
        guard symlinkat(destination, fd, name) == 0 else { throw conflict("Cannot create the skill link. Existing files are preserved.") }
    }
    func descendant(_ path: String, create: Bool = false) throws -> Directory? {
        var current: Directory = self
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        if parts.isEmpty { return current }
        for part in parts {
            guard part != "..", let next = try current.child(part, create: create) else { return nil }
            current = next
        }
        return current
    }
    func read(_ name: String, limit: Int) throws -> Data {
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw conflict("Skill files must be readable regular files") }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw conflict("Skill files must be private, bounded regular files with no links") }
        var data = Data(count: limit + 1)
        let count = data.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
        guard count >= 0, count <= limit, count == info.st_size else { throw conflict("The skill changed while it was being read") }
        data.count = count
        return data
    }
    func write(_ name: String, data: Data) throws {
        let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ChauffeurError("skill_unavailable", "Cannot write the coordination skill") }
        defer { close(file) }
        let count = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(file) == 0 else { throw ChauffeurError("skill_unavailable", "Cannot save the coordination skill") }
    }
    func writePath(_ path: String, data: Data) throws {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2, let name = parts.last,
              let parent = try descendant(parts.dropLast().joined(separator: "/"), create: true) else {
            throw ChauffeurError("skill_bundle", "A bundled skill reference path is invalid")
        }
        try parent.write(name, data: data)
    }
    func lock(_ name: String) throws -> Int32 {
        let file = openat(fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw conflict("Cannot acquire the profile's Chauffeur skill lock") }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_size == 0 else {
            close(file); throw conflict("The profile's Chauffeur skill lock has unexpected contents")
        }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else { close(file); throw ChauffeurError("skill_busy", "Another Chauffeur process is changing this profile's skill. Retry after it finishes") }
        return file
    }
    func move(_ source: String, to destination: String, in target: Directory? = nil) throws {
        guard renameatx_np(fd, source, target?.fd ?? fd, destination, UInt32(RENAME_EXCL)) == 0 else { throw conflict("The skill path changed or cannot be replaced. Existing files are preserved.") }
        _ = fsync(fd)
        if let target { _ = fsync(target.fd) }
    }
}
