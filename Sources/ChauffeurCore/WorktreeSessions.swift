import Foundation

/// Groups a project's sessions by the checkout they run in, so the project
/// window can list them under a repository's worktree rows.
public enum WorktreeSessions {
    /// Sessions running in `path` for `folder`. The main checkout is the folder
    /// path itself. Worktree records are matched by ID first; sessions launched
    /// before a worktree record existed fall back to their working directory.
    public static func sessions(_ sessions: [Session], folder: ProjectFolder, path: String, worktrees: [Worktree]) -> [Session] {
        let canonical = Paths.canonical(path)
        let worktreeIDs = Set(worktrees.filter { $0.folderID == folder.id && Paths.canonical($0.path) == canonical }.map(\.id))
        return sessions.filter { session in
            guard session.folderID == folder.id else { return false }
            if let id = session.worktreeID {
                if worktreeIDs.contains(id) { return true }
                // Its worktree record still exists elsewhere: not this checkout.
                if worktrees.contains(where: { $0.id == id }) { return false }
            }
            return Paths.canonical(session.launch.workingDirectory) == canonical
        }.sorted(by: order)
    }
    /// Live sessions first, then by creation time.
    public static func order(_ first: Session, _ second: Session) -> Bool {
        if first.state.isLive != second.state.isLive { return first.state.isLive }
        return first.createdAt < second.createdAt
    }
    public static func live(_ sessions: [Session]) -> [Session] { sessions.filter(\.state.isLive) }
    public static func finished(_ sessions: [Session]) -> [Session] { sessions.filter { !$0.state.isLive } }
    /// Sessions a checkout badge counts: only live work still needs attention,
    /// so a checkout left with finished sessions carries no badge.
    public static func attentionCount(_ sessions: [Session]) -> Int { live(sessions).filter(\.needsAttention).count }
}
