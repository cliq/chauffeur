import Foundation
import ChauffeurRemoteProtocol

/// Lookups the screens need over the wire inventory. Checkouts are keyed by path, which is
/// `CheckoutSummary.id` and `SessionSummary.checkoutPath`.
extension InventorySnapshot {
    func project(_ id: UUID) -> ProjectSummary? {
        projects.first { $0.id == id }
    }

    func folder(_ id: UUID) -> FolderSummary? {
        for project in projects {
            if let folder = project.folders.first(where: { $0.id == id }) {
                return folder
            }
        }
        return nil
    }

    func checkout(path: String) -> CheckoutSummary? {
        for project in projects {
            for folder in project.folders {
                if let checkout = folder.checkouts.first(where: { $0.path == path }) {
                    return checkout
                }
            }
        }
        return nil
    }

    func session(_ id: UUID) -> SessionSummary? {
        sessions.first { $0.id == id }
    }
}

extension ProjectSummary {
    var defaultGroup: GroupSummary? {
        groups.first(where: \.isDefault) ?? groups.first
    }
}

extension RemoteSessionKind {
    var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .shell: "Shell"
        }
    }
}
