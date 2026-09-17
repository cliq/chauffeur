import Foundation

public struct GitWorktree: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var commit: String
    public var branch: String
    public var locked: Bool
    public var prunable: Bool
    public var gitIdentity: UUID?
    public var availability: Availability?
    /// Tracked modifications or untracked files in the checkout. Ignored files
    /// do not count. `nil` until the runtime has inspected the checkout.
    public var hasUncommittedChanges: Bool?
    /// Commits on this checkout's branch that `baseBranch` does not contain.
    /// `nil` when the base is unknown, gone, or is this branch itself.
    public var unmergedCommits: Int?
    /// The branch `unmergedCommits` is measured against: the branch the worktree
    /// started from when Chauffeur created it, otherwise the main checkout's branch.
    public var baseBranch: String?
    public var id: String { path }
    public init(path: String, commit: String, branch: String, locked: Bool, prunable: Bool) {
        self.path = path; self.commit = commit; self.branch = branch; self.locked = locked; self.prunable = prunable
    }
}

public struct RepositoryInventory: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, notRepository, missing, inaccessible, failed }
    public var sourcePath: String
    public var sourcePaths: [String]?
    public var repositoryID: UUID?
    public var legacyRepositoryID: UUID?
    public var entries: [GitWorktree] = []
    public var observedAt = Date()
    public var status: Status
    public var error: ChauffeurError?
    public init(sourcePath: String, status: Status) { self.sourcePath = sourcePath; self.status = status }
}

public extension Array where Element == RepositoryInventory {
    /// The observation covering a project folder, whether it was scanned
    /// directly or grouped under another path of the same repository.
    func observation(for folderPath: String) -> RepositoryInventory? {
        first { $0.sourcePath == folderPath || $0.sourcePaths?.contains(folderPath) == true }
    }
}

/// What a project window may claim about a folder's Git checkouts. Until the
/// runtime has reported the folder, nothing is known: not its worktrees, not the
/// main checkout's branch. Showing "no worktrees" then would be a guess.
public enum InventoryReadiness: Equatable, Sendable {
    /// No observation yet; the first scan after registering the folder is still running.
    case pending
    case ready
    case notRepository
    /// The scan could not inspect the folder; a refresh may recover.
    case failed(String)
    public static func of(folderPath: String, inventories: [RepositoryInventory]?) -> InventoryReadiness {
        guard let inventory = inventories?.observation(for: folderPath) else { return .pending }
        switch inventory.status {
        case .available: return .ready
        case .notRepository: return .notRepository
        case .missing: return .failed(inventory.error?.errorDescription ?? "The folder is missing")
        case .inaccessible: return .failed(inventory.error?.errorDescription ?? "The folder is not accessible")
        case .failed: return .failed(inventory.error?.errorDescription ?? "Git inventory could not be read")
        }
    }
    public var isPending: Bool { self == .pending }
}

/// What `previewWorktreeDeletion` reports before the user confirms a removal.
public struct WorktreeDeletionPreview: Codable, Equatable, Sendable {
    /// Uncommitted, untracked, or ignored files: everything removal deletes.
    public var hasChanges: Bool
    public var unmergedCommits: Int?
    public var baseBranch: String?
    public init(hasChanges: Bool, unmergedCommits: Int? = nil, baseBranch: String? = nil) {
        self.hasChanges = hasChanges; self.unmergedCommits = unmergedCommits; self.baseBranch = baseBranch
    }
    /// Warnings the confirmation shows before the removal description, one per
    /// line. Empty when nothing would be lost.
    public var warnings: [String] {
        var lines: [String] = []
        if hasChanges { lines.append("This worktree has uncommitted, untracked, or ignored files. These changes will be permanently lost.") }
        if let unmergedCommits, unmergedCommits > 0 {
            let commits = "\(unmergedCommits) commit\(unmergedCommits == 1 ? "" : "s")"
            let base = baseBranch.map { " into \($0)" } ?? ""
            lines.append("Its branch has \(commits) not merged\(base). The branch is kept, but it no longer has a checkout.")
        }
        return lines
    }
    public var warningText: String { warnings.isEmpty ? "" : warnings.joined(separator: "\n") + "\n\n" }
}
