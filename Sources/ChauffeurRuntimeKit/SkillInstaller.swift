import Foundation
import Darwin
import ChauffeurCore

/// Owns only skills/chauffeur. The receipt and the exact bytes must agree before
/// replacing or removing anything. An unmanaged directory is never adopted.
public actor SkillInstaller {
    private let skill: CoordinationSkill
    private static let names: Set<String> = ["SKILL.md", ".chauffeur-install.json"]
    private struct Receipt: Codable {
        var schema = 1
        var owner = "dev.chauffeur.coordination-skill"
        var version: String
        var digest: String
    }
    public init(skill: CoordinationSkill) { self.skill = skill }

    public func status(directory: String) -> SkillInstallation {
        let path = URL(fileURLWithPath: Paths.canonical(directory)).appendingPathComponent("skills/chauffeur").path
        do {
            let profile = try Directory(path: Paths.directory(directory))
            guard let skills = try profile.child("skills"), let target = try skills.child("chauffeur") else {
                return result(.notInstalled, path: path, message: "The Chauffeur skill is not installed.")
            }
            let receipt = try inspect(target)
            let current = receipt.version == skill.version && receipt.digest == skill.digest
            return result(current ? .installed : .updateAvailable, path: path, receipt: receipt,
                          message: current ? "The bundled version is installed." : "A different Chauffeur version is installed. Updating replaces its unchanged guidance.")
        } catch let error as ChauffeurError {
            return result(error.code == "skill_conflict" ? .conflict : .unavailable, path: path, message: error.message)
        } catch { return result(.unavailable, path: path, message: "Cannot inspect this profile's skill directory.") }
    }

    public func install(directory: String, revision: String) throws -> SkillInstallation {
        try mutate(directory: directory, revision: revision, removing: false)
    }
    public func remove(directory: String, revision: String) throws -> SkillInstallation {
        try mutate(directory: directory, revision: revision, removing: true)
    }

    private func result(_ state: SkillInstallation.State, path: String, receipt: Receipt? = nil, message: String) -> SkillInstallation {
        let revision = JSONCoding.digest(Data("\(path)\n\(state.rawValue)\n\(receipt?.version ?? "")\n\(receipt?.digest ?? "")".utf8))
        return SkillInstallation(state: state, path: path, bundledVersion: skill.version, installedVersion: receipt?.version, message: message, revision: revision)
    }

    private func inspect(_ directory: Directory) throws -> Receipt {
        guard try directory.names() == Self.names else { throw conflict("Existing or additional files need manual review. Chauffeur will preserve them.") }
        let data = try directory.read("SKILL.md", limit: 65_536)
        let receiptData = try directory.read(".chauffeur-install.json", limit: 4096)
        let receipt: Receipt
        do { receipt = try JSONCoding.decode(Receipt.self, from: receiptData) }
        catch { throw conflict("This directory has no valid Chauffeur installation receipt. Its files are preserved.") }
        guard try JSONCoding.encode(receipt) == receiptData, receipt.schema == 1, receipt.owner == "dev.chauffeur.coordination-skill",
              receipt.digest == JSONCoding.digest(data),
              (try? CoordinationSkill(version: receipt.version, document: data)) != nil else {
            throw conflict("The installed skill was edited or its receipt is invalid. Its files are preserved.")
        }
        return receipt
    }

    private func mutate(directory: String, revision: String, removing: Bool) throws -> SkillInstallation {
        let profile = try Directory(path: Paths.directory(directory))
        // A persistent zero-byte lock coordinates runtimes using different data
        // stores but the same CLI profile. Never unlink a lock another process
        // may already have opened.
        let lock = try profile.lock(".chauffeur-skill.lock")
        defer { flock(lock, LOCK_UN); close(lock) }
        let before = status(directory: directory)
        guard before.revision == revision else { throw ChauffeurError("edit_conflict", "The profile or skill changed. Refresh its status before continuing") }
        guard [.notInstalled, .installed, .updateAvailable].contains(before.state) else { throw conflict(before.message) }
        if removing && before.state == .notInstalled || !removing && before.state == .installed { return before }
        let skills = try profile.child("skills", create: true)!
        let stageName = ".chauffeur-install-\(UUID().uuidString)"
        let retiredName = ".chauffeur-retired-\(UUID().uuidString)"
        var staged: Directory?
        if !removing {
            // Stage outside skills/ so CLI watchers never discover a partial
            // install or the retained copy of a removed skill.
            let stage = try profile.child(stageName, create: true)!
            staged = stage
            do {
                try stage.write("SKILL.md", data: skill.document)
                try stage.write(".chauffeur-install.json", data: JSONCoding.encode(Receipt(version: skill.version, digest: skill.digest)))
            } catch {
                try? stage.removeKnownFiles(); try? profile.removeEmpty(stageName); throw error
            }
        }
        defer {
            // Cleanup never descends recursively or removes unknown files.
            if let staged { try? staged.removeKnownFiles(); try? profile.removeEmpty(stageName) }
        }
        var retired: Directory?
        if before.state != .notInstalled {
            try skills.move("chauffeur", to: retiredName, in: profile)
            do {
                guard let previous = try profile.child(retiredName) else { throw conflict("The skill directory changed during the operation") }
                retired = previous
                let receipt = try inspect(previous)
                let observed = result(before.state, path: before.path, receipt: receipt, message: "")
                guard observed.revision == before.revision else { throw conflict("The skill changed during the operation. Refresh before continuing.") }
            } catch {
                try restore(profile, skills: skills, retiredName: retiredName)
                throw error
            }
        }
        if !removing {
            do { try profile.move(stageName, to: "chauffeur", in: skills); staged = nil }
            catch {
                if retired != nil { try restore(profile, skills: skills, retiredName: retiredName) }
                throw error
            }
        }
        if let retired {
            do { try retired.removeKnownFiles(); try profile.removeEmpty(retiredName) }
            catch { throw conflict("The skill changed during cleanup. Review the preserved .chauffeur-retired directory in this configuration directory.") }
        }
        return status(directory: directory)
    }

    private func restore(_ profile: Directory, skills: Directory, retiredName: String) throws {
        do { try profile.move(retiredName, to: "chauffeur", in: skills) }
        catch { throw conflict("Another file appeared during the operation. Review the preserved .chauffeur-retired directory in this configuration directory.") }
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
    func names() throws -> Set<String> {
        let duplicate = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard duplicate >= 0 else { throw conflict("Cannot inspect the skill directory") }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw conflict("Cannot inspect the skill directory") }
        defer { closedir(stream) }
        var result = Set<String>()
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.insert(name) }
        }
        guard errno == 0 else { throw conflict("Cannot inspect the skill directory") }
        return result
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
    func removeKnownFiles() throws {
        guard try names().isSubset(of: ["SKILL.md", ".chauffeur-install.json"]) else { throw conflict("Additional skill files are preserved") }
        for name in ["SKILL.md", ".chauffeur-install.json"] {
            // unlinkat removes only the named entry, never a symlink's target.
            guard unlinkat(fd, name, 0) == 0 || errno == ENOENT else { throw conflict("Cannot remove a skill file") }
        }
    }
    func removeEmpty(_ name: String) throws {
        guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw conflict("The skill directory contains additional files or changed during removal") }
        _ = fsync(fd)
    }
}
