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
    /// Saved tabs precede newly opened tabs, which retain their existing order.
    public static func orderedTabs(_ sessions: [Session], savedOrder: [UUID]) -> [Session] {
        let rank = Dictionary(savedOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        return sessions.enumerated().sorted {
            let left = rank[$0.element.id] ?? Int.max, right = rank[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
    /// Move only within the displayed checkout; retain other checkouts' ordering.
    public static func movingTab(_ source: UUID, to target: UUID, displayed: [UUID], savedOrder: [UUID]) -> [UUID] {
        guard source != target, let from = displayed.firstIndex(of: source), let to = displayed.firstIndex(of: target) else { return savedOrder }
        var moved = displayed
        moved.remove(at: from); moved.insert(source, at: to)
        let local = Set(displayed)
        return savedOrder.filter { !local.contains($0) } + moved
    }

    /// Live sessions first, then by creation time.
    public static func order(_ first: Session, _ second: Session) -> Bool {
        if first.state.isLive != second.state.isLive { return first.state.isLive }
        return first.createdAt < second.createdAt
    }
    /// Preserve a valid selection; otherwise choose the nearest live tab,
    /// preferring the left neighbor. Finished history is a fallback when no live tab remains.
    public static func selection(in sessions: [Session], selectedID: UUID?, previousOrder: [UUID] = []) -> UUID? {
        if let selectedID, sessions.contains(where: { $0.id == selectedID }) { return selectedID }
        let live = live(sessions)
        let candidates = live.isEmpty ? sessions : live
        guard let selectedID, let index = previousOrder.firstIndex(of: selectedID) else { return candidates.first?.id }
        let available = Set(candidates.map(\.id))
        for distance in 1...max(previousOrder.count, 1) {
            let left = index - distance, right = index + distance
            if left >= 0, available.contains(previousOrder[left]) { return previousOrder[left] }
            if right < previousOrder.count, available.contains(previousOrder[right]) { return previousOrder[right] }
        }
        return candidates.first?.id
    }
    public static func live(_ sessions: [Session]) -> [Session] { sessions.filter(\.state.isLive) }
    public static func finished(_ sessions: [Session]) -> [Session] { sessions.filter { !$0.state.isLive } }
    /// Sessions a checkout badge counts: only live work still needs attention,
    /// so a checkout left with finished sessions carries no badge.
    public static func attentionCount(_ sessions: [Session]) -> Int { live(sessions).filter(\.needsAttention).count }
}
