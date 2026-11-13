import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import ChauffeurCore
import CChauffeur

public actor WorktreeManager {
    private let root: URL
    /// Earlier managed roots. Checkouts there stay managed and removable, but
    /// new checkouts are only created under `root`.
    private let legacyRoots: [URL]
    private var reservations = Set<String>()
    /// Where each observed checkout keeps its Git metadata, keyed by checkout
    /// path, and each repository's shared directory. The scanner watches these
    /// to tell which checkouts changed between scans.
    private(set) var gitDirectories: [String: String] = [:]
    private(set) var commonDirectories: [UUID: String] = [:]
    /// How many Git processes this manager started, so tests can tell a scan
    /// that reused its previous result from one that read the repository.
    private(set) var gitInvocations = 0
    /// Git runs checkout filters such as `git-lfs` from this search path, so it
    /// must include where the user installed them (for example /opt/homebrew/bin).
    private let searchPath: String
    public init(root: URL, legacyRoots: [URL] = [], searchPath: String = "/usr/bin:/bin") {
        self.root = URL(fileURLWithPath: Paths.canonical(root.path))
        self.legacyRoots = legacyRoots.map { URL(fileURLWithPath: Paths.canonical($0.path)) }
        self.searchPath = searchPath
    }
    /// Whether a canonical path lies inside the current or a legacy managed root.
    public func isManagedPath(_ path: String) -> Bool {
        ([root] + legacyRoots).contains { path.hasPrefix($0.path + "/") }
    }
    private func git(_ directory: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> String {
        // Without optional locks `git status` does not rewrite the index, so
        // inspecting a checkout neither races the user's Git commands nor
        // produces the file events that would mark it changed again.
        gitInvocations += 1
        let result = try await ProcessRunner.run("/usr/bin/git", ["-C", directory] + arguments, environment: ["PATH": searchPath, "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LC_ALL": "en_US.UTF-8", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"], timeout: timeout)
        guard result.status == 0, !result.outputTruncated else {
            throw ChauffeurError("git_failed", String(result.error.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines), path: directory)
        }
        return result.output
    }
    public func repositoryID(at path: String) async throws -> UUID {
        try await repositoryIdentities(at: path).current
    }
    func legacyRepositoryID(at path: String) async throws -> UUID {
        Self.identifier(Paths.canonical(Self.line(try await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))))
    }
    /// Both repository identities from one Git call.
    private func repositoryIdentities(at path: String) async throws -> (current: UUID, legacy: UUID) {
        let common = Paths.canonical(Self.line(try await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])))
        let current = try Self.directoryIdentity(at: common)
        commonDirectories[current] = common
        return (current, Self.identifier(common))
    }
    /// The repository and checkout identities of a checkout from one Git call.
    private func checkoutIdentities(at path: String) async throws -> (repository: UUID, checkout: UUID) {
        let lines = try await git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir", "--absolute-git-dir"]).split(separator: "\n").map(String.init)
        guard lines.count == 2 else { throw ChauffeurError("git_failed", "Git did not report the checkout's metadata directories", path: path) }
        let common = Paths.canonical(lines[0]), directory = Paths.canonical(lines[1])
        let repository = try Self.directoryIdentity(at: common)
        commonDirectories[repository] = common
        gitDirectories[Paths.canonical(path)] = directory
        return (repository, try Self.directoryIdentity(at: directory))
    }
    /// The checkout containing `path` and its repository's main checkout, or nil
    /// outside a checkout. A bare repository or a submodule has no main checkout.
    func checkoutRoots(at path: String) async -> (main: String?, worktree: String)? {
        guard let output = try? await git(path, ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"], timeout: 5) else { return nil }
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return nil }
        let common = URL(fileURLWithPath: Paths.canonical(lines[1]))
        return (common.lastPathComponent == ".git" ? common.deletingLastPathComponent().path : nil, Paths.canonical(lines[0]))
    }
    private static func line(_ output: String) -> String { output.hasSuffix("\n") ? String(output.dropLast()) : output }
    static func identifier(_ value: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    public func identity(at path: String) async throws -> UUID {
        let directory = Paths.canonical(Self.line(try await git(path, ["rev-parse", "--absolute-git-dir"])))
        return try Self.directoryIdentity(at: directory)
    }
    private static func directoryIdentity(at directory: String) throws -> UUID {
        var info = stat()
        guard stat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ChauffeurError("worktree_unavailable", "Directory identity is unavailable", path: directory) }
        // The administrative directory survives `git worktree move`. Its inode
        // also distinguishes a removed/recreated worktree with the same name.
        // The device number is left out: macOS reassigns it across restarts.
        var seconds: Int64 = 0, nanoseconds = 0
        guard chauffeur_birth_time(directory, &seconds, &nanoseconds) == 0 else {
            // Some Linux file systems record no creation time; a reused inode can then
            // be mistaken for the removed worktree.
            return Self.identifier("\(info.st_ino)")
        }
        return Self.identifier("\(info.st_ino):\(seconds):\(nanoseconds)")
    }
    private static func hasGitMetadata(above path: String) -> Bool {
        var directory = URL(fileURLWithPath: path), initial = stat()
        guard stat(path, &initial) == 0 else { return true }
        while true {
            var info = stat()
            guard stat(directory.path, &info) == 0 else { return true }
            if info.st_dev != initial.st_dev { return false } // Git's discovery boundary.
            if lstat(directory.appendingPathComponent(".git").path, &info) == 0 { return true }
            if directory.path == "/" { return false }
            directory.deleteLastPathComponent()
        }
    }
    func checkoutIdentity(at path: String) async throws -> CheckoutIdentity {
        let canonical = try Paths.directory(path)
        let directory = try Self.directoryIdentity(at: canonical)
        let gitIdentity: UUID?
        do { gitIdentity = try await identity(at: canonical) }
        catch let error as ChauffeurError where error.code == "git_failed"
            && error.message.hasPrefix("fatal: not a git repository (or any") && !Self.hasGitMetadata(above: canonical) {
            // Git runs with an English locale. Other failures (including broken
            // .git files and unreadable metadata) must not become non-Git paths.
            gitIdentity = nil
        }
        try Task.checkCancellation()
        guard try Self.directoryIdentity(at: canonical) == directory else {
            throw ChauffeurError("checkout_changed", "The checkout changed while its identity was being checked. Retry after the filesystem operation finishes", path: path)
        }
        return CheckoutIdentity(path: canonical, directoryIdentity: directory, gitIdentity: gitIdentity)
    }
    func validateResume(_ launch: LaunchSnapshot) async throws {
        let paths = [launch.workingDirectory] + launch.additionalPaths
        if let recorded = launch.checkoutIdentities {
            guard recorded.map(\.path) == paths else {
                throw ChauffeurError("checkout_unverified", "Saved checkout identities do not match this session's paths. Create a new session")
            }
            for checkout in recorded {
                guard try await checkoutIdentity(at: checkout.path) == checkout else {
                    throw ChauffeurError("checkout_changed", "A different checkout occupies this session's path. Restore the original checkout to resume, or create a new session", path: checkout.path)
                }
            }
        } else {
            // Older snapshots omitted non-Git paths from their ordered UUIDs.
            // Only a complete one-to-one list can prove each path's identity.
            guard let identities = launch.gitWorktreeIdentities, identities.count == paths.count else {
                throw ChauffeurError("checkout_unverified", "This older session has no complete checkout identity record. Create a new session to use the current folders")
            }
            for (path, expected) in zip(paths, identities) {
                _ = try Paths.directory(path)
                guard try await identity(at: path) == expected else {
                    throw ChauffeurError("checkout_changed", "A different checkout occupies this session's path. Restore the original checkout to resume, or create a new session", path: path)
                }
                try Task.checkCancellation()
            }
        }
    }
    public func inventory(at path: String) async throws -> [GitWorktree] {
        try await inventory(at: path, repositoryID: try await repositoryID(at: path))
    }
    private func inventory(at path: String, repositoryID: UUID) async throws -> [GitWorktree] {
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
                let identities = try await checkoutIdentities(at: entries[index].path)
                guard identities.repository == repositoryID else { throw ChauffeurError("worktree_unavailable", "Path belongs to a different Git repository", path: entries[index].path) }
                entries[index].gitIdentity = identities.checkout
                entries[index].availability = .available
            } catch let error as ChauffeurError {
                entries[index].availability = error.code == "missing_directory" ? .missing : .inaccessible
            } catch { entries[index].availability = .inaccessible }
        }
        return entries
    }
    public func observe(at path: String, cached: [UUID: RepositoryInventory] = [:]) async -> RepositoryInventory {
        let path = Paths.canonical(path)
        var result = RepositoryInventory(sourcePath: path, status: .available)
        do {
            _ = try Paths.directory(path)
            let identities = try await repositoryIdentities(at: path)
            result.repositoryID = identities.current
            result.legacyRepositoryID = identities.legacy
            if var previous = cached[identities.current] {
                previous.sourcePath = path
                return previous
            }
            result.entries = try await inventory(at: path, repositoryID: identities.current)
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
        let knownCheckout = worktree.gitIdentity.map { identity in inventory.entries.contains { $0.gitIdentity == identity && $0.availability == .available } } ?? false
        let legacyMatch = worktree.repositoryIdentityVersion == nil && (knownCheckout || inventory.legacyRepositoryID == worktree.repositoryID)
        // Identities older than the current version cannot match again, so the
        // record re-links once to the checkout Git reports at its path.
        let relinksByPath = (worktree.repositoryIdentityVersion ?? 0) < CheckoutIdentity.currentVersion
        let pathMatch = relinksByPath && (inventory.entries.contains { $0.path == worktree.path }
            || inventory.sourcePath == worktree.repositoryPath || inventory.sourcePaths?.contains(worktree.repositoryPath) == true)
        guard inventory.status == .available, inventory.repositoryID == worktree.repositoryID || legacyMatch || pathMatch else {
            result.availability = inventory.status == .missing ? .missing : .inaccessible
            return result
        }
        let entry: GitWorktree?
        if relinksByPath { entry = inventory.entries.first { $0.path == worktree.path } }
        else if let identity = worktree.gitIdentity {
            entry = inventory.entries.first { $0.gitIdentity == identity }
                ?? inventory.entries.first { $0.path == worktree.path && $0.gitIdentity == nil }
        } else { entry = inventory.entries.first { $0.path == worktree.path } }
        guard let entry else { result.availability = .missing; return result }
        result.path = entry.path; result.branch = entry.branch
        result.repositoryPath = inventory.sourcePath
        result.gitIdentity = entry.gitIdentity ?? result.gitIdentity
        result.availability = entry.availability ?? .available
        if relinksByPath, result.availability == .available, let repositoryID = inventory.repositoryID, entry.gitIdentity != nil {
            result.repositoryID = repositoryID; result.repositoryIdentityVersion = CheckoutIdentity.currentVersion
        }
        // Moving a checkout out of managed storage transfers its cleanup to the
        // user. Registering/moving it back does not silently regain ownership.
        if !isManagedPath(entry.path) { result.managed = false }
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
    public func previewDestination(folder: ProjectFolder, branch: String) async throws -> URL {
        let repository = try Paths.directory(folder.canonicalPath)
        try await validateBranch(branch, repository: repository)
        return destination(repositoryID: try await repositoryID(at: repository), branch: branch)
    }
    private func validateBranch(_ branch: String, repository: String) async throws {
        try Validation.require(!branch.isEmpty && !branch.hasPrefix("-") && !branch.contains("\0"), "Branch is required and cannot begin with '-' or contain NUL")
        _ = try await git(repository, ["check-ref-format", "--branch", branch])
    }
    public func create(projectID: UUID, folder: ProjectFolder, branch: String, baseRef: String, reuseExistingBranch: Bool = false) async throws -> Worktree {
        let repository = try Paths.directory(folder.canonicalPath)
        try Validation.require(!baseRef.isEmpty && !baseRef.hasPrefix("-") && !baseRef.contains("\0"), "Base ref is required and cannot begin with '-' or contain NUL")
        try await validateBranch(branch, repository: repository)
        // An existing branch only a remote holds is checked out as a new branch tracking it.
        let remoteRef = reuseExistingBranch ? try await remoteBranch(for: branch, repository: repository) : nil
        let startRef = reuseExistingBranch ? remoteRef ?? "refs/heads/\(branch)" : baseRef
        if reuseExistingBranch, let occupied = try await inventory(at: repository).first(where: { $0.branch == branch }) {
            throw ChauffeurError("branch_in_use", "This branch is already checked out at \(occupied.path). Select that checkout instead.", path: occupied.path)
        }
        let baseCommit = try await git(repository, ["rev-parse", "--verify", "\(startRef)^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let baseBranchName = reuseExistingBranch ? nil : (try? await branchName(of: baseRef, repository: repository)) ?? nil
        let repoID = try await repositoryID(at: repository)
        let destination = destination(repositoryID: repoID, branch: branch)
        reservations.insert(destination.path); defer { reservations.remove(destination.path) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let arguments = remoteRef.map { ["--track", "-b", branch, "--", destination.path, $0] }
            ?? (reuseExistingBranch ? ["--", destination.path, branch] : ["-b", branch, "--", destination.path, baseCommit])
        _ = try await git(repository, ["worktree", "add"] + arguments, timeout: 600)  // checkout filters (LFS) may download
        var result = Worktree(projectID: projectID, folderID: folder.id, repositoryID: repoID, path: Paths.canonical(destination.path), repositoryPath: repository, branch: branch, baseCommit: baseCommit, managed: true)
        result.baseBranch = baseBranchName
        result.gitIdentity = try? await identity(at: result.path)
        return result
    }
    /// The remote branch to check out `branch` from when no local branch has that
    /// name: `origin`'s when it has one, otherwise the only remote's that does.
    private func remoteBranch(for branch: String, repository: String) async throws -> String? {
        guard (try? await git(repository, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)^{commit}"])) == nil else { return nil }
        let remotes = try await git(repository, ["remote"]).split(separator: "\n").map(String.init)
        var matches: [String] = []
        for remote in remotes where (try? await git(repository, ["rev-parse", "--verify", "--quiet", "refs/remotes/\(remote)/\(branch)^{commit}"])) != nil {
            matches.append(remote)
        }
        let remote = matches.contains("origin") ? "origin" : matches.count == 1 ? matches[0] : nil
        guard let remote else {
            if matches.isEmpty { return nil }
            throw ChauffeurError("ambiguous_remote_branch", "Remotes \(matches.joined(separator: ", ")) each have a branch named \(branch). Create a local branch from the one you want")
        }
        return "refs/remotes/\(remote)/\(branch)"
    }
    /// Removes a checkout with `git worktree remove`. External checkouts are
    /// only deleted when the caller explicitly asks for it. Its branch goes too
    /// when no other branch needs its commits, unless `keepBranch` is set;
    /// `forceDeleteBranch` deletes it even when its commits exist nowhere else.
    public func remove(_ worktree: Worktree, liveSessions: [Session], allowExternal: Bool = false, discardChanges: Bool = false, keepBranch: Bool = false, forceDeleteBranch: Bool = false) async throws {
        let path = Paths.canonical(worktree.path)
        if !allowExternal {
            guard worktree.managed else { throw ChauffeurError("external_worktree", "External worktrees can only be unregistered") }
            guard isManagedPath(path) else { throw ChauffeurError("unmanaged_path", "Worktree is outside Chauffeur's managed directory", path: path) }
        }
        guard path != Paths.canonical(worktree.repositoryPath) else { throw ChauffeurError("main_checkout", "The main checkout cannot be removed", path: path) }
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
        let dirty = try await hasChanges(at: path)
        guard discardChanges || !dirty else {
            throw ChauffeurError("dirty_worktree", "Worktree has uncommitted or untracked files. Confirm deletion to discard them", path: path)
        }
        let submodules = try await self.submodules(at: path, mainCheckout: worktree.repositoryPath)
        guard discardChanges || !submodules.contains(where: { $0.localCommits > 0 }) else {
            throw ChauffeurError("submodule_work", "Submodules have commits found only in this worktree. Confirm deletion to discard them", path: path)
        }
        // Git refuses any checkout holding submodule repositories unless forced;
        // the checks above stand in for its own. It still enforces locks and
        // refuses to remove the main checkout.
        let modules = Self.line(try await git(path, ["rev-parse", "--path-format=absolute", "--git-path", "modules"]))
        let force = discardChanges || !submodules.isEmpty || FileManager.default.fileExists(atPath: modules)
        _ = try await git(worktree.repositoryPath, ["worktree", "remove"] + (force ? ["--force"] : []) + ["--", path])
        if !keepBranch { await deleteBranchIfUnused(entry.branch, repository: worktree.repositoryPath, force: forceDeleteBranch) }
    }
    public func hasChanges(at path: String) async throws -> Bool {
        try await hasUncommittedChanges(at: path)
    }
    /// Initialized submodules, recursively, each with the commits that vanish
    /// along with the checkout's copy of its repository: those its HEAD or
    /// branches reach that neither its remotes nor a ref in the main checkout's
    /// copy of the same submodule hold.
    public func submodules(at path: String, mainCheckout: String) async throws -> [WorktreeDeletionPreview.Submodule] {
        let listing = try await git(path, ["submodule", "foreach", "--recursive", "--quiet", #"printf '%s\0' "$displaypath""#])
        var result: [WorktreeDeletionPreview.Submodule] = []
        for displayPath in listing.split(separator: "\0").map(String.init) {
            let submodule = URL(fileURLWithPath: path).appendingPathComponent(displayPath).path
            let copy = URL(fileURLWithPath: mainCheckout).appendingPathComponent(displayPath).path
            let hasCopy = FileManager.default.fileExists(atPath: URL(fileURLWithPath: copy).appendingPathComponent(".git").path)
            let heads = try await git(submodule, ["for-each-ref", "--format=%(objectname)", "refs/heads"]).split(separator: "\n").map(String.init)
            let head = (try? await git(submodule, ["rev-parse", "--verify", "--quiet", "HEAD"])).map(Self.line)
            var lost: [String] = []
            for tip in Set(heads + [head].compactMap { $0 }).sorted() where !tip.isEmpty {
                guard let count = Int(Self.line(try await git(submodule, ["rev-list", "--count", tip, "--not", "--remotes"]))), count > 0 else { continue }
                let kept = hasCopy ? (try? await git(copy, ["for-each-ref", "--count=1", "--format=kept", "--contains", tip]))?.isEmpty == false : false
                if !kept { lost.append(tip) }
            }
            let count = lost.isEmpty ? 0 : Int(Self.line(try await git(submodule, ["rev-list", "--count"] + lost + ["--not", "--remotes"]))) ?? 0
            result.append(.init(path: displayPath, localCommits: count))
        }
        return result
    }
    public func changedFiles(at path: String) async throws -> [WorktreeDeletionPreview.ChangedFile] {
        // Disable rename folding so every affected path is shown, including both
        // sides of a rename. NUL delimiters preserve spaces and newlines in names.
        let output = try await git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames", "--ignore-submodules=none"])
        return output.split(separator: "\0").map { record in
            WorktreeDeletionPreview.ChangedFile(path: String(record.dropFirst(3)), status: String(record.prefix(2)))
        }
    }
    /// Whether the checkout has work to commit: tracked modifications or
    /// untracked files, including inside submodules whatever `.gitmodules`
    /// says to ignore. Ignored files are build output, not pending work.
    public func hasUncommittedChanges(at path: String) async throws -> Bool {
        try await !git(path, ["status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=none"]).isEmpty
    }
    /// The local branch a ref names (`HEAD` resolves to the checked-out branch),
    /// or `nil` for a detached commit, tag, or remote ref.
    public func branchName(of ref: String, repository: String) async throws -> String? {
        let reference = Self.line(try await git(repository, ["rev-parse", "--symbolic-full-name", "--verify", "--quiet", "--end-of-options", ref]))
        return reference.hasPrefix("refs/heads/") ? String(reference.dropFirst("refs/heads/".count)) : nil
    }
    /// Commits reachable from `branch` but not from `base`, or `nil` when either
    /// branch is gone or they are the same branch.
    public func unmergedCommits(at path: String, branch: String, base: String?) async -> Int? {
        guard let base, !branch.isEmpty, base != branch else { return nil }
        guard let count = try? await git(path, ["rev-list", "--count", "--end-of-options", "refs/heads/\(base)..refs/heads/\(branch)"]) else { return nil }
        return Int(count.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// Which remote branch holds this checkout's branch and how many commits it
    /// lacks. The configured upstream wins; otherwise any remote branch that
    /// already contains HEAD counts as fully pushed.
    public func remoteStatus(at path: String) async -> (remoteBranch: String?, unpushedCommits: Int?) {
        if let upstream = try? await git(path, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"]) {
            let count = try? await git(path, ["rev-list", "--count", "@{upstream}..HEAD"])
            return (Self.line(upstream), count.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        }
        if let listing = try? await git(path, ["branch", "-r", "--contains", "HEAD", "--format=%(refname:short)"]),
           let remote = listing.split(separator: "\n").map(String.init).first(where: { !$0.isEmpty && !$0.hasSuffix("/HEAD") }) {
            return (remote, 0)
        }
        return (nil, nil)
    }
    /// Adds working-tree and unmerged-commit status to available entries. The
    /// first entry is the main checkout, whose branch is the fallback base for
    /// worktrees Chauffeur did not create. A checkout that cannot be inspected
    /// keeps `nil` status rather than a guess.
    public func annotated(_ entries: [GitWorktree], baseBranch: (GitWorktree) -> String?) async -> [GitWorktree] {
        var entries = entries
        let mainBranch = entries.first?.branch ?? ""
        for index in entries.indices where entries[index].availability ?? .available == .available {
            let path = entries[index].path
            entries[index].hasUncommittedChanges = try? await hasUncommittedChanges(at: path)
            guard index > 0 else { continue } // The main checkout has no starting point.
            let base = baseBranch(entries[index]) ?? (mainBranch.isEmpty ? nil : mainBranch)
            entries[index].baseBranch = base
            entries[index].unmergedCommits = await unmergedCommits(at: path, branch: entries[index].branch, base: base)
        }
        return entries
    }
    /// Deletes a branch no checkout uses once no other branch needs its
    /// commits. `force` skips the commit check, discarding commits only it holds.
    public func deleteBranchIfUnused(_ branch: String, repository: String, force: Bool = false) async {
        guard !branch.isEmpty else { return } // Detached HEAD.
        let reference = "refs/heads/" + branch
        do {
            let commit = Self.line(try await git(repository, ["rev-parse", "--verify", reference]))
            if !force {
                let unique = try await git(repository, ["rev-list", "--count", commit, "--not", "--exclude=" + branch, "--branches"])
                guard unique.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else { return }
            }
            guard try await !inventory(at: repository).contains(where: { $0.branch == branch }) else { return }
            // Compare-and-delete preserves a branch advanced during the check.
            _ = try await git(repository, ["update-ref", "-d", reference, commit])
        } catch {
            // Conservatively keep the branch if its safety cannot be proven.
            // The checkout is already removed; history cleanup must still run.
        }
    }
    /// Drops Git's entries for worktrees whose directories no longer exist.
    public func prune(repositoryPath: String) async throws {
        _ = try await git(repositoryPath, ["worktree", "prune"])
    }
}
