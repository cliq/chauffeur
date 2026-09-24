import Foundation
import CryptoKit
import ChauffeurCore
import ChauffeurRemoteProtocol

/// Translates the runtime's full snapshot into the portable inventory the
/// mobile client renders. The checkout rows mirror the desktop's
/// `CheckoutRows` so both surfaces list the same main checkout and worktrees.
public struct RemoteInventoryBuilder {
    /// The subset of `RuntimeCoordinator.snapshot()` the inventory needs.
    struct RuntimeSnapshotView: Decodable {
        var store: StoreSnapshot
        var sessions: [Session]
        var repositoryInventories: [RepositoryInventory]?
    }

    public static func build(snapshot: JSONValue, hostName: String, revision: UInt64, isAttached: (UUID) -> Bool) throws -> InventorySnapshot {
        let view = try snapshot.decode(RuntimeSnapshotView.self)
        return build(view: view, hostName: hostName, revision: revision, isAttached: isAttached)
    }

    static func build(view: RuntimeSnapshotView, hostName: String, revision: UInt64, isAttached: (UUID) -> Bool) -> InventorySnapshot {
        let store = view.store
        let inventories = view.repositoryInventories ?? []
        let worktrees = store.worktrees.map(\.value)
        let projects = store.projects.map(\.value)

        var summaries: [ProjectSummary] = []
        for project in projects {
            let groups = project.groups.filter { !$0.archived }.map { GroupSummary(id: $0.id, name: $0.name, isDefault: $0.isDefault) }
            let set = store.presetSets.first { $0.value.id == project.presetSetID }?.value
            let presets: [PresetSummary] = set?.archived == false
                ? store.agents(teamID: project.presetSetID).map { PresetSummary(id: $0.id, name: $0.name, kind: kind($0.kind)) }
                : []
            let folders = project.folders.filter(\.registered).map { folder -> FolderSummary in
                let inventory = inventories.observation(for: folder.canonicalPath)
                return FolderSummary(
                    id: folder.id,
                    name: folder.name,
                    path: folder.canonicalPath,
                    isRepository: inventory?.status == .available,
                    inventoryReady: inventory != nil,
                    availability: availability(folder.availability),
                    checkouts: checkouts(folder: folder, project: project, records: worktrees, inventory: inventory)
                )
            }
            summaries.append(ProjectSummary(id: project.id, name: project.name, archived: project.archived, groups: groups, presets: presets, folders: folders))
        }
        summaries.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var sessions: [SessionSummary] = []
        for session in view.sessions {
            let worktree = session.worktreeID.flatMap { id in worktrees.first { $0.id == id } }
            let branch: String?
            if let worktree {
                branch = worktree.branch
            } else {
                let folder = projects.first { $0.id == session.projectID }?.folders.first { $0.id == session.folderID }
                let main = folder.flatMap { folder in inventories.observation(for: folder.canonicalPath)?.entries.first { $0.path == folder.canonicalPath } }
                branch = main.flatMap { $0.branch.isEmpty ? nil : $0.branch }
            }
            sessions.append(SessionSummary(
                id: session.id,
                projectID: session.projectID,
                folderID: session.folderID,
                worktreeID: session.worktreeID,
                title: session.title,
                kind: kind(session.launch.preset.kind),
                state: RemoteSessionState(rawValue: session.state.rawValue) ?? .activityUnknown,
                needsAttention: session.needsAttention,
                branch: branch,
                checkoutPath: session.launch.workingDirectory,
                attached: isAttached(session.id),
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                progress: RemoteProgressReader.summary(session: session)
            ))
        }
        sessions.sort { $0.createdAt < $1.createdAt }

        return InventorySnapshot(revision: revision, hostName: hostName, projects: summaries, sessions: sessions, generatedAt: Date())
    }

    /// The main checkout first, then every worktree Git lists (matched to its
    /// record when one exists), then records Git has not reported yet.
    static func checkouts(folder: ProjectFolder, project: Project, records allRecords: [Worktree], inventory: RepositoryInventory?) -> [CheckoutSummary] {
        let records = allRecords.filter { $0.projectID == project.id && $0.folderID == folder.id }
        let entries = inventory?.entries ?? []
        let mainBranch = entries.first { $0.path == folder.canonicalPath }?.branch ?? ""
        let main = CheckoutSummary(kind: .main, worktreeID: nil, branch: mainBranch, path: folder.canonicalPath, availability: availability(folder.availability), managed: false)
        var rows: [CheckoutSummary] = []
        var matched = Set<UUID>()
        for entry in entries where entry.path != folder.canonicalPath {
            let record = records.first { $0.path == entry.path || (entry.gitIdentity != nil && $0.gitIdentity == entry.gitIdentity) }
            if let record { matched.insert(record.id) }
            let entryAvailability = entry.availability ?? .available
            // A stale Git entry nothing refers to is left for Manage Worktrees to prune.
            if entryAvailability != .available && record == nil { continue }
            rows.append(CheckoutSummary(kind: .worktree, worktreeID: record?.id, branch: entry.branch, path: entry.path, availability: availability(entryAvailability), managed: record?.managed ?? false))
        }
        for record in records where !matched.contains(record.id) && record.path != folder.canonicalPath && !rows.contains(where: { $0.path == record.path }) {
            // Only a live record without an inventory entry yet (a creation the
            // scan has not caught up with) is worth showing.
            guard record.registered, record.availability == .available else { continue }
            rows.append(CheckoutSummary(kind: .worktree, worktreeID: record.id, branch: record.branch, path: record.path, availability: .available, managed: record.managed))
        }
        rows.sort { $0.branch.localizedStandardCompare($1.branch) == .orderedAscending }
        return [main] + rows
    }

    /// Lowercase hex SHA-256 of the snapshot's content, ignoring `revision` and
    /// `generatedAt`, so callers can bump the revision only when content changes.
    public static func digest(_ snapshot: InventorySnapshot) -> String {
        var normalized = snapshot
        normalized.revision = 0
        normalized.generatedAt = Date(timeIntervalSince1970: 0)
        // Encoding these value types cannot fail; an empty digest would still be stable.
        let data = (try? RemoteJSON.encode(normalized)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func kind(_ kind: CLIKind) -> RemoteSessionKind {
        switch kind {
        case .codex: .codex
        case .claude: .claude
        case .opencode: .opencode
        case .shell: .shell
        }
    }

    static func availability(_ availability: Availability) -> RemoteAvailability {
        RemoteAvailability(rawValue: availability.rawValue) ?? .missing
    }
}
