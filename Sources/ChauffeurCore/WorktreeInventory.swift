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
    /// Tracked modifications or untracked files that removal would discard.
    public var hasChanges: Bool
    public var changedFiles: [ChangedFile]?
    public var unmergedCommits: Int?
    public var baseBranch: String?
    /// Commits the branch's remote counterpart lacks. Zero means everything is
    /// pushed; `nil` means no remote branch contains this branch at all.
    public var unpushedCommits: Int?
    /// The remote branch the push state was measured against.
    public var remoteBranch: String?
    public init(hasChanges: Bool, unmergedCommits: Int? = nil, baseBranch: String? = nil, unpushedCommits: Int? = nil, remoteBranch: String? = nil, changedFiles: [ChangedFile]? = nil) {
        self.hasChanges = hasChanges; self.unmergedCommits = unmergedCommits; self.baseBranch = baseBranch
        self.unpushedCommits = unpushedCommits; self.remoteBranch = remoteBranch
        self.changedFiles = changedFiles
    }
    public struct ChangedFile: Codable, Equatable, Sendable, Identifiable {
        public var path: String
        public var status: String
        public var id: String { path }
        public init(path: String, status: String) {
            self.path = path; self.status = status
        }
        public var description: String {
            let kind: String
            if status == "??" { kind = "Untracked" }
            else if status.contains("U") || status == "AA" || status == "DD" { kind = "Conflicted" }
            else if status.contains("D") { kind = "Deleted" }
            else if status.contains("A") { kind = "Added" }
            else if status.contains("T") { kind = "Type changed" }
            else { kind = "Modified" }
            return "\(kind): \(path)"
        }
    }
    /// Every commit on the branch is on a remote, so removing the checkout cannot lose work.
    public var isPushed: Bool { remoteBranch != nil && unpushedCommits == 0 }

    public enum Severity: Sendable, Equatable {
        /// Nothing is lost.
        case safe
        /// Work disappears with the checkout.
        case loss
        /// A consequence worth knowing that loses nothing.
        case note
    }
    public struct Item: Equatable, Sendable, Identifiable {
        public var severity: Severity
        public var text: String
        public var id: String { text }
        public init(_ severity: Severity, _ text: String) { self.severity = severity; self.text = text }
    }
    /// The checklist a deletion confirmation shows: one line per fact about
    /// the checkout, marked safe or lossy, so the reader does not parse prose.
    public func items(branch: String, finishedSessions: Int, checkoutMissing: Bool) -> [Item] {
        var items: [Item] = []
        if checkoutMissing {
            items.append(Item(.note, "The checkout is already gone"))
        } else {
            items.append(hasChanges ? Item(.loss, "Uncommitted or untracked files will be permanently lost") : Item(.safe, "No uncommitted changes"))
            let base = baseBranch.map { " into \($0)" } ?? ""
            switch unmergedCommits {
            case nil:
                items.append(Item(.note, "Merge state is unknown"))
            case 0?:
                items.append(Item(.safe, "All commits are merged\(base)"))
            case let count?:
                let commits = "\(count) commit\(count == 1 ? "" : "s") not merged\(base)"
                if isPushed, let remoteBranch {
                    items.append(Item(.safe, "\(commits), all pushed to \(remoteBranch)"))
                } else if let remoteBranch, let unpushedCommits {
                    items.append(Item(.loss, "\(commits), \(unpushedCommits) not pushed to \(remoteBranch)"))
                } else {
                    items.append(Item(.loss, "\(commits), not pushed to any remote"))
                }
            }
            if !branch.isEmpty, let unmergedCommits {
                items.append(Item(.note, unmergedCommits > 0 ? "Branch \(branch) is kept" : "Branch \(branch) is deleted too"))
            }
        }
        items.append(finishedSessions > 0
            ? Item(.loss, "\(finishedSessions) finished session\(finishedSessions == 1 ? "" : "s") and their terminal history are deleted")
            : Item(.safe, "No session history is affected"))
        return items
    }
}
