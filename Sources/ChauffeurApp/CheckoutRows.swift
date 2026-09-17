import Foundation
import ChauffeurCore

/// One checkout of a repository as the project window and worktree manager list
/// it: the main checkout, a worktree Git currently reports, or a checkout that is
/// gone but still has session history.
struct CheckoutRow: Identifiable {
    let folderID: UUID
    let path: String
    let branch: String
    let availability: Availability
    let worktreeID: UUID?
    let isMain: Bool
    let managed: Bool
    let sessions: [Session]
    /// Git status from the last inventory scan; `nil` until the checkout was inspected.
    var hasUncommittedChanges: Bool? = nil
    var unmergedCommits: Int? = nil
    var baseBranch: String? = nil
    var id: String { path }
    var title: String { branch.isEmpty ? (isMain ? "Main checkout" : "Detached HEAD") : branch }
    /// The checkout no longer exists; the row only carries history.
    var finished: Bool { availability != .available }
    var liveSessions: [Session] { WorktreeSessions.live(sessions) }
    var statusLabel: String? {
        switch availability {
        case .available: nil
        case .missing: "Finished"
        case .inaccessible: "Inaccessible"
        }
    }
    /// Commits the base branch lacks; zero when the branch is merged or unknown.
    var unmergedCount: Int { finished ? 0 : (unmergedCommits ?? 0) }
    var isDirty: Bool { !finished && hasUncommittedChanges == true }
    var unmergedDescription: String? {
        guard unmergedCount > 0 else { return nil }
        return "\(unmergedCount) commit\(unmergedCount == 1 ? "" : "s") not merged" + (baseBranch.map { " into \($0)" } ?? "")
    }
    /// The status facts the worktree manager lists after availability.
    var gitStatusLabels: [String] { (isDirty ? ["Uncommitted changes"] : []) + (unmergedDescription.map { [$0] } ?? []) }
    mutating func applyStatus(from entry: GitWorktree?) {
        hasUncommittedChanges = entry?.hasUncommittedChanges
        unmergedCommits = entry?.unmergedCommits
        baseBranch = entry?.baseBranch
    }
}

enum CheckoutRows {
    /// Every worktree Git lists for the folder, plus records whose checkout is
    /// gone but still referenced by sessions. Git entries whose directory is
    /// gone appear only when sessions refer to them.
    static func rows(folder: ProjectFolder, project: Project, records: [Worktree], inventory: RepositoryInventory?, sessions: [Session], pending: Worktree? = nil) -> [CheckoutRow] {
        var records = records.filter { $0.projectID == project.id && $0.folderID == folder.id }
        if let pending, pending.folderID == folder.id, !records.contains(where: { $0.id == pending.id }) { records.append(pending) }
        let entries = inventory?.entries ?? []
        let allSessions = sessions
        func history(at path: String) -> [Session] { WorktreeSessions.sessions(allSessions, folder: folder, path: path, worktrees: records) }
        let mainEntry = entries.first { $0.path == folder.canonicalPath }
        var main = CheckoutRow(folderID: folder.id, path: folder.canonicalPath, branch: mainEntry?.branch ?? "", availability: folder.availability, worktreeID: nil, isMain: true, managed: false, sessions: history(at: folder.canonicalPath))
        main.applyStatus(from: mainEntry)
        var rows: [CheckoutRow] = []
        var matched = Set<UUID>()
        for entry in entries where entry.path != folder.canonicalPath {
            let record = records.first { $0.path == entry.path || (entry.gitIdentity != nil && $0.gitIdentity == entry.gitIdentity) }
            if let record { matched.insert(record.id) }
            let history = history(at: entry.path)
            let availability = entry.availability ?? .available
            // A stale Git entry with no history is left for Manage Worktrees to prune.
            if availability != .available && history.isEmpty { continue }
            var row = CheckoutRow(folderID: folder.id, path: entry.path, branch: entry.branch, availability: availability, worktreeID: record?.id, isMain: false, managed: record?.managed ?? false, sessions: history)
            row.applyStatus(from: entry)
            rows.append(row)
        }
        for record in records where !matched.contains(record.id) && record.path != folder.canonicalPath && !rows.contains(where: { $0.path == record.path }) {
            let history = history(at: record.path)
            // The runtime drops session-less records for vanished checkouts; a
            // pending creation is the one record that may briefly lack an entry.
            guard !history.isEmpty || record.id == pending?.id else { continue }
            let availability: Availability = record.id == pending?.id ? record.availability : (record.availability == .available ? .missing : record.availability)
            rows.append(CheckoutRow(folderID: folder.id, path: record.path, branch: record.branch, availability: availability, worktreeID: record.id, isMain: false, managed: record.managed, sessions: history))
        }
        rows.sort { $0.branch.localizedStandardCompare($1.branch) == .orderedAscending }
        return [main] + rows
    }
    /// Git entries whose directory is gone and nothing refers to; `git worktree prune` clears them.
    static func staleEntries(folder: ProjectFolder, inventory: RepositoryInventory?, rows: [CheckoutRow]) -> [GitWorktree] {
        (inventory?.entries ?? []).filter { entry in (entry.availability ?? .available) != .available && !rows.contains { $0.path == entry.path } }
    }
}
