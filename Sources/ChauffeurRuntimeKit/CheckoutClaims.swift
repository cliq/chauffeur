import Foundation
import ChauffeurCore

/// Accessed synchronously by RuntimeCoordinator before crossing an await.
/// Claims bridge preflight/spawn and Git removal, when actor reentrancy otherwise
/// permits a launch to pass a removal's earlier live-session check.
struct CheckoutClaims {
    private struct Launch {
        var paths: [String]
        var worktreeID: UUID?
        var gitIdentities: Set<UUID> = []
        var allowSharedCheckout = true
    }
    private struct Removal {
        var path: String
        var worktreeIDs: Set<UUID>
        var gitIdentity: UUID?
    }
    private var launches: [UUID: Launch] = [:]
    private var removals: [UUID: Removal] = [:]

    static func overlap(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second == "/" ? "/" : second + "/") || second.hasPrefix(first == "/" ? "/" : first + "/")
    }
    mutating func beginLaunch(_ id: UUID, paths: [String], worktreeID: UUID?, allowSharedCheckout: Bool = true) throws {
        let paths = paths.map(Paths.canonical)
        guard !removals.values.contains(where: { removal in
            worktreeID.map { removal.worktreeIDs.contains($0) } == true || paths.contains { Self.overlap($0, removal.path) }
        }) else { throw ChauffeurError("worktree_busy", "A checkout needed by this session is being removed. Retry after removal finishes") }
        guard allowSharedCheckout || !launches.contains(where: { $0.key != id && $0.value.paths.first == paths.first }) else {
            throw ChauffeurError("shared_checkout", "Another session is starting in this checkout. Wait for it to appear, then explicitly choose to share it")
        }
        launches[id] = Launch(paths: paths, worktreeID: worktreeID)
        launches[id]?.allowSharedCheckout = allowSharedCheckout
    }
    mutating func setGitIdentities(_ id: UUID, identities: [UUID], primary: UUID? = nil) throws {
        let identities = Set(identities)
        guard !removals.values.contains(where: { $0.gitIdentity.map(identities.contains) == true }) else {
            throw ChauffeurError("worktree_busy", "A checkout needed by this session is being removed")
        }
        if let primary, launches[id]?.allowSharedCheckout == false,
           launches.contains(where: { $0.key != id && $0.value.gitIdentities.contains(primary) }) {
            throw ChauffeurError("shared_checkout", "Another session is starting in this checkout. Wait for it to appear, then explicitly choose to share it")
        }
        launches[id]?.gitIdentities = identities
    }
    mutating func endLaunch(_ id: UUID) { launches.removeValue(forKey: id) }
    mutating func beginRemoval(_ id: UUID, path: String, worktreeIDs: Set<UUID>, gitIdentity: UUID? = nil, sessions: [Session]) throws {
        let path = Paths.canonical(path)
        let isUsed: ([String], UUID?, Set<UUID>) -> Bool = { paths, treeID, identities in
            treeID.map { worktreeIDs.contains($0) } == true || gitIdentity.map(identities.contains) == true || paths.contains { Self.overlap(Paths.canonical($0), path) }
        }
        guard !sessions.contains(where: { $0.state.isLive && isUsed([$0.launch.workingDirectory] + $0.launch.additionalPaths, $0.worktreeID, Set($0.launch.gitWorktreeIdentities ?? [])) }),
              !launches.values.contains(where: { isUsed($0.paths, $0.worktreeID, $0.gitIdentities) }) else {
            throw ChauffeurError("active_worktree", "Stop sessions using or starting in this worktree before removal", path: path)
        }
        guard !removals.values.contains(where: { Self.overlap($0.path, path) || !$0.worktreeIDs.isDisjoint(with: worktreeIDs) }) else {
            throw ChauffeurError("worktree_busy", "Another removal is in progress", path: path)
        }
        removals[id] = Removal(path: path, worktreeIDs: worktreeIDs, gitIdentity: gitIdentity)
    }
    mutating func endRemoval(_ id: UUID) { removals.removeValue(forKey: id) }
    func isRemoving(path: String, worktreeID: UUID) -> Bool {
        removals.values.contains { $0.worktreeIDs.contains(worktreeID) || Self.overlap(Paths.canonical(path), $0.path) }
    }
}
