// TODO: replace with ChauffeurRemoteProtocol
// `ChauffeurRemoteProtocol` is still a placeholder in this tree. These local types mirror the
// inventory shapes the mobile screens need so the swap to the real module is mechanical:
// delete this file, `import ChauffeurRemoteProtocol`, and fix any renamed members.
import Foundation

struct InventorySnapshot: Hashable, Sendable {
    var hostName: String
    var capturedAt: Date
    var projects: [ProjectSummary]
    var sessions: [SessionSummary]
    var presets: [AgentPreset]
    var groups: [SessionGroup]
}

struct ProjectSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var folders: [FolderSummary]
}

/// A repository or plain folder registered under a project.
struct FolderSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var isGitRepository: Bool
    var checkouts: [CheckoutSummary]
}

struct CheckoutSummary: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case main
        case worktree
    }

    let id: UUID
    var kind: Kind
    var branch: String
    var path: String
}

enum SessionKind: String, Hashable, Sendable, CaseIterable {
    case codex
    case claude
    case shell

    var label: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .shell: "Shell"
        }
    }
}

enum SessionState: Hashable, Sendable {
    case running
    case waitingForInput
    case ended

    var label: String {
        switch self {
        case .running: "Running"
        case .waitingForInput: "Waiting for input"
        case .ended: "Ended"
        }
    }
}

struct SessionSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var kind: SessionKind
    var state: SessionState
    var needsAttention: Bool
    var projectID: UUID
    var folderID: UUID
    var checkoutID: UUID
    var branch: String
    /// The desktop app currently shows this session's terminal.
    var isOpenOnMac: Bool
}

struct AgentPreset: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var kind: SessionKind
}

struct SessionGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var isDefault: Bool
}

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

    func checkout(_ id: UUID) -> CheckoutSummary? {
        for project in projects {
            for folder in project.folders {
                if let checkout = folder.checkouts.first(where: { $0.id == id }) {
                    return checkout
                }
            }
        }
        return nil
    }

    func session(_ id: UUID) -> SessionSummary? {
        sessions.first { $0.id == id }
    }

    func sessions(inProject projectID: UUID) -> [SessionSummary] {
        sessions.filter { $0.projectID == projectID }
    }

    func sessions(inCheckout checkoutID: UUID) -> [SessionSummary] {
        sessions.filter { $0.checkoutID == checkoutID }
    }

    var defaultGroup: SessionGroup? {
        groups.first(where: \.isDefault) ?? groups.first
    }
}
