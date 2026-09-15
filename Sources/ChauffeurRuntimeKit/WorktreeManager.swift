import Foundation
import CryptoKit
import Darwin
import ChauffeurCore

public actor WorktreeManager {
    private let root: URL
    private var reservations = Set<String>()
    public init(root: URL) { self.root = URL(fileURLWithPath: Paths.canonical(root.path)) }
    private func git(_ directory: String, _ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/git", ["-C", directory] + arguments, environment: ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LC_ALL": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0"], timeout: 30)
        guard result.status == 0, !result.outputTruncated else {
            throw ChauffeurError("git_failed", String(result.error.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines), path: directory)
        }
        return result.output
    }
    public func repositoryID(at path: String) async throws -> UUID {
        let common = try await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        return Self.identifier(Paths.canonical(Self.line(common)))
    }
    private static func line(_ output: String) -> String { output.hasSuffix("\n") ? String(output.dropLast()) : output }
    private static func identifier(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    public func identity(at path: String) async throws -> UUID {
        let directory = Paths.canonical(Self.line(try await git(path, ["rev-parse", "--absolute-git-dir"])))
        var info = stat()
        guard stat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ChauffeurError("worktree_unavailable", "Git worktree identity is unavailable", path: path) }
        // The administrative directory survives `git worktree move`. Its inode
        // also distinguishes a removed/recreated worktree with the same name.
        return Self.identifier("\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)")
    }
    public func inventory(at path: String) async throws -> [GitWorktree] {
        let repositoryID = try await repositoryID(at: path)
        let output = try await git(path, ["worktree", "list", "--porcelain", "-z"])
        var entries: [GitWorktree] = [], current: GitWorktree?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = GitWorktree(path: Paths.canonical(String(field.dropFirst(9))), commit: "", branch: "", locked: false, prunable: false)
            } else if field.hasPrefix("HEAD ") { current?.commit = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") {
                let reference = String(field.dropFirst(7))
                current?.branch = reference.hasPrefix("refs/heads/") ? String(reference.dropFirst("refs/heads/".count)) : reference
            }
            else if field.hasPrefix("locked") { current?.locked = true }
            else if field.hasPrefix("prunable") { current?.prunable = true }
        }
        if let current { entries.append(current) }
        for index in entries.indices {
            do {
                _ = try Paths.directory(entries[index].path)
                guard try await self.repositoryID(at: entries[index].path) == repositoryID else { throw ChauffeurError("worktree_unavailable", "Path belongs to a different Git repository", path: entries[index].path) }
                entries[index].gitIdentity = try await identity(at: entries[index].path)
                entries[index].availability = .available
            } catch let error as ChauffeurError {
                entries[index].availability = error.code == "missing_directory" ? .missing : .inaccessible
            } catch { entries[index].availability = .inaccessible }
        }
        return entries
    }
    public func observe(at path: String, cached: [UUID: RepositoryInventory] = [:]) async -> RepositoryInventory {
        var result = RepositoryInventory(sourcePath: path, status: .available)
        do {
            _ = try Paths.directory(path)
            result.repositoryID = try await repositoryID(at: path)
            if let id = result.repositoryID, var previous = cached[id] {
                previous.sourcePath = path
                return previous
            }
            result.entries = try await inventory(at: path)
        } catch let error as ChauffeurError {
            switch error.code {
            case "missing_directory": result.status = .missing
            case "inaccessible_directory": result.status = .inaccessible
            default:
                result.status = FileManager.default.fileExists(atPath: path + "/.git") ? .failed : .notRepository
            }
            if result.status != .notRepository { result.error = error }
        } catch {
            result.status = .failed; result.error = ChauffeurError("worktree_unavailable", "Cannot read Git worktree inventory", path: path)
        }
        result.observedAt = Date()
        return result
    }
    public func reconciled(_ worktree: Worktree, inventory: RepositoryInventory) -> Worktree {
        var result = worktree
        guard inventory.status == .available, inventory.repositoryID == worktree.repositoryID else {
            result.availability = inventory.status == .missing ? .missing : .inaccessible
            return result
        }
        let entry: GitWorktree?
        if let identity = worktree.gitIdentity {
            entry = inventory.entries.first { $0.gitIdentity == identity }
                ?? inventory.entries.first { $0.path == worktree.path && $0.gitIdentity == nil }
        } else { entry = inventory.entries.first { $0.path == worktree.path } }
        guard let entry else { result.availability = .missing; return result }
        result.path = entry.path; result.branch = entry.branch
        result.repositoryPath = inventory.sourcePath
        result.gitIdentity = entry.gitIdentity ?? result.gitIdentity
        result.availability = entry.availability ?? .available
        // Moving a checkout out of managed storage transfers its cleanup to the
        // user. Registering/moving it back does not silently regain ownership.
        if !entry.path.hasPrefix(root.path + "/") { result.managed = false }
        return result
    }
    public func destination(repositoryID: UUID, branch: String) -> URL {
        let parent = root.appendingPathComponent(repositoryID.uuidString)
        let slug = Paths.slug(branch)
        var suffix = 1
        while true {
            let path = parent.appendingPathComponent(suffix == 1 ? slug : "\(slug)-\(suffix)")
            if !FileManager.default.fileExists(atPath: path.path) && !reservations.contains(path.path) { return path }
            suffix += 1
        }
    }
    public func create(projectID: UUID, folder: ProjectFolder, branch: String, baseRef: String) async throws -> Worktree {
        let repository = try Paths.directory(folder.canonicalPath)
        try Validation.require(!branch.isEmpty && !branch.hasPrefix("-") && !baseRef.isEmpty && !baseRef.hasPrefix("-") && !branch.contains("\0") && !baseRef.contains("\0"), "Branch and base ref are required and cannot begin with '-' or contain NUL")
        _ = try await git(repository, ["check-ref-format", "--branch", branch])
        let baseCommit = try await git(repository, ["rev-parse", "--verify", "\(baseRef)^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let repoID = try await repositoryID(at: repository)
        let destination = destination(repositoryID: repoID, branch: branch)
        reservations.insert(destination.path); defer { reservations.remove(destination.path) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try await git(repository, ["worktree", "add", "-b", branch, "--", destination.path, baseCommit])
        var result = Worktree(projectID: projectID, folderID: folder.id, repositoryID: repoID, path: Paths.canonical(destination.path), repositoryPath: repository, branch: branch, baseCommit: baseCommit, managed: true)
        result.gitIdentity = try? await identity(at: result.path)
        return result
    }
    public func remove(_ worktree: Worktree, liveSessions: [Session]) async throws {
        guard worktree.managed else { throw ChauffeurError("external_worktree", "External worktrees can only be unregistered") }
        let path = Paths.canonical(worktree.path)
        let managedRoot = Paths.canonical(root.path) + "/"
        guard path.hasPrefix(managedRoot) else { throw ChauffeurError("unmanaged_path", "Worktree is outside Chauffeur's managed directory", path: path) }
        guard !liveSessions.contains(where: { session in
            session.state.isLive && (session.worktreeID == worktree.id
                || worktree.gitIdentity.map { (session.launch.gitWorktreeIdentities ?? []).contains($0) } == true
                || ([session.launch.workingDirectory] + session.launch.additionalPaths).contains { CheckoutClaims.overlap(Paths.canonical($0), path) })
        }) else {
            throw ChauffeurError("active_worktree", "Stop sessions using this worktree before removal", path: path)
        }
        guard !reservations.contains(path) else { throw ChauffeurError("worktree_busy", "Another worktree operation is in progress", path: path) }
        reservations.insert(path); defer { reservations.remove(path) }
        let inventory = try await inventory(at: worktree.repositoryPath)
        guard let entry = inventory.first(where: { $0.path == path }), !entry.locked else { throw ChauffeurError("worktree_unavailable", "Worktree is missing or locked", path: path) }
        guard worktree.gitIdentity == nil || entry.gitIdentity == worktree.gitIdentity else { throw ChauffeurError("worktree_unavailable", "A different checkout now occupies this path. Refresh the Git inventory", path: path) }
        guard try await git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).isEmpty else {
            throw ChauffeurError("dirty_worktree", "Worktree has modified or untracked files", path: path)
        }
        _ = try await git(worktree.repositoryPath, ["worktree", "remove", "--", path])
    }
}
