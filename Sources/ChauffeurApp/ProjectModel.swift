import Foundation
import ChauffeurCore

/// One project window's share of the app state. It publishes only when this
/// project's data changes, so a snapshot that touches another project leaves
/// the window's body, sidebar and layout alone.
@MainActor final class ProjectModel: ObservableObject {
    struct Slice: Equatable {
        var project: Project?
        var sessions: [Session] = []
        var worktrees: [Worktree] = []
        /// Observations of this project's folders, without scan times: a rescan
        /// that found nothing new is not a change. `nil` until the runtime reports any.
        var inventories: [RepositoryInventory]?
        var online = false
        var keepFinishedSessions = false
        /// Routes to this project only; another project's navigation leaves the window alone.
        var pendingSessionRoute: AppModel.Navigation?
        var pendingProjectRoute: AppModel.ProjectNavigation?
    }
    let id: UUID
    @Published private(set) var slice: Slice
    private var checkouts: [UUID: [CheckoutRow]] = [:]
    private var canonicalPaths: [String: String] = [:]
    init(id: UUID, slice: Slice) { self.id = id; self.slice = slice }
    func update(_ next: Slice) {
        guard next != slice else { return }
        slice = next; checkouts = [:]; canonicalPaths = [:]
    }
    /// `Paths.canonical`, resolved on disk once per change of this project.
    func canonical(_ path: String) -> String {
        if let known = canonicalPaths[path] { return known }
        let value = Paths.canonical(path); canonicalPaths[path] = value; return value
    }
    /// The folder's checkout rows, built once per change of this project.
    func checkouts(for folder: ProjectFolder, project: Project, inventory: RepositoryInventory?) -> [CheckoutRow] {
        if let known = checkouts[folder.id] { return known }
        let rows = CheckoutRows.rows(folder: folder, project: project, records: slice.worktrees, inventory: inventory, sessions: slice.sessions, canonicalize: canonical)
        checkouts[folder.id] = rows; return rows
    }
}
