import Foundation
import CryptoKit
import ChauffeurCore

public struct GitWorktree: Codable, Sendable {
    public var path: String
    public var commit: String
    public var branch: String
    public var locked: Bool
    public var prunable: Bool
}

public actor WorktreeManager {
    private let root: URL
    private var reservations = Set<String>()
    public init(root: URL) { self.root = root }
    private func git(_ directory: String, _ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/git", ["-C", directory] + arguments, environment: ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LC_ALL": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0"], timeout: 30)
        guard result.status == 0 else {
            throw ChauffeurError("git_failed", String(result.error.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines), path: directory)
        }
        return result.output
    }
    public func repositoryID(at path: String) async throws -> UUID {
        let common = try await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(SHA256.hash(data: Data(Paths.canonical(common).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    public func inventory(at path: String) async throws -> [GitWorktree] {
        let output = try await git(path, ["worktree", "list", "--porcelain", "-z"])
        var entries: [GitWorktree] = [], current: GitWorktree?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.hasPrefix("worktree ") {
                if let current { entries.append(current) }
                current = GitWorktree(path: Paths.canonical(String(field.dropFirst(9))), commit: "", branch: "", locked: false, prunable: false)
            } else if field.hasPrefix("HEAD ") { current?.commit = String(field.dropFirst(5)) }
            else if field.hasPrefix("branch ") { current?.branch = String(field.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if field.hasPrefix("locked") { current?.locked = true }
            else if field.hasPrefix("prunable") { current?.prunable = true }
        }
        if let current { entries.append(current) }
        return entries
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
        return Worktree(projectID: projectID, folderID: folder.id, repositoryID: repoID, path: Paths.canonical(destination.path), repositoryPath: repository, branch: branch, baseCommit: baseCommit, managed: true)
    }
    public func remove(_ worktree: Worktree, liveSessions: [Session]) async throws {
        guard worktree.managed else { throw ChauffeurError("external_worktree", "External worktrees can only be unregistered") }
        let path = Paths.canonical(worktree.path)
        let managedRoot = Paths.canonical(root.path) + "/"
        guard path.hasPrefix(managedRoot) else { throw ChauffeurError("unmanaged_path", "Worktree is outside Chauffeur's managed directory", path: path) }
        guard !liveSessions.contains(where: { $0.state.isLive && ($0.launch.workingDirectory == path || $0.launch.workingDirectory.hasPrefix(path + "/") || $0.launch.additionalPaths.contains { $0 == path || $0.hasPrefix(path + "/") }) }) else {
            throw ChauffeurError("active_worktree", "Stop sessions using this worktree before removal", path: path)
        }
        guard !reservations.contains(path) else { throw ChauffeurError("worktree_busy", "Another worktree operation is in progress", path: path) }
        reservations.insert(path); defer { reservations.remove(path) }
        let inventory = try await inventory(at: worktree.repositoryPath)
        guard let entry = inventory.first(where: { $0.path == path }), !entry.locked else { throw ChauffeurError("worktree_unavailable", "Worktree is missing or locked", path: path) }
        guard try await git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).isEmpty else {
            throw ChauffeurError("dirty_worktree", "Worktree has modified or untracked files", path: path)
        }
        _ = try await git(worktree.repositoryPath, ["worktree", "remove", "--", path])
    }
}
