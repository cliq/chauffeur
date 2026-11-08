import SwiftUI
import ChauffeurRemoteProtocol

/// A launch location in one row: project and repository above the checkout, or above the
/// worktree the Mac will create, with how many sessions already run there.
struct LocationSummary: View {
    var model: MobileAppModel
    let location: LaunchLocation
    var showsLiveCount = true

    private var project: ProjectSummary? { model.inventory?.project(location.projectID) }
    private var folder: FolderSummary? { model.inventory?.folder(location.folderID) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                // A repository named like its project would only repeat it.
                Text((folder?.name == project?.name ? [project?.name] : [project?.name, folder?.name]).compactMap { $0 }.joined(separator: " › "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                switch location.checkout {
                case .existing(let path):
                    let checkout = folder?.checkouts.first { $0.path == path }
                    CheckoutLabel(kind: checkout?.kind ?? .main, branch: checkout?.branch ?? URL(fileURLWithPath: path).lastPathComponent,
                                  path: path, isRepository: folder?.isRepository ?? true,
                                  unavailable: checkout.map { $0.availability != .available } ?? true)
                case .newWorktree(let draft):
                    NewWorktreeLabel(draft: draft)
                }
            }
            Spacer(minLength: 8)
            if showsLiveCount, case .existing(let path) = location.checkout {
                LiveSessionsBadge(count: model.liveSessionCount(checkoutPath: path))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The worktree a launch will create, laid out like `CheckoutLabel`.
struct NewWorktreeLabel: View {
    let draft: NewWorktreeDraft

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "plus.square.on.square")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                BranchText(branch: draft.branch)
                Text(draft.reuseExistingBranch ? "New worktree · existing branch" : "New worktree from \(draft.baseRef)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let destination = draft.destination {
                    Text(destination)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A project in the new-session lists.
struct ProjectRow: View {
    var model: MobileAppModel
    let project: ProjectSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                Text(project.folders.count == 1 ? "1 repository" : "\(project.folders.count) repositories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            LiveSessionsBadge(count: model.liveSessionCount(projectID: project.id))
        }
        .accessibilityElement(children: .combine)
    }
}

/// A repository or folder in the new-session lists; `subtitle` replaces its path.
struct RepositoryRow: View {
    var model: MobileAppModel
    let folder: FolderSummary
    var subtitle: String?

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: folder.isRepository ? "folder" : "folder.badge.minus")
            }
            Spacer(minLength: 8)
            LiveSessionsBadge(count: model.liveSessionCount(folderID: folder.id))
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [subtitle ?? abbreviatedPath(folder.path)]
        if !folder.isRepository { parts.append("Not a Git repository") }
        if folder.availability != .available { parts.append("Unavailable") }
        return parts.joined(separator: " · ")
    }
}

/// How many live sessions run in a place; nothing when none do.
struct LiveSessionsBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count) active")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.14), in: Capsule())
                .fixedSize()
                .accessibilityLabel(count == 1 ? "1 active session" : "\(count) active sessions")
        }
    }
}

/// A Mac or Linux home folder shortened to `~`.
func abbreviatedPath(_ path: String) -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home" else { return path }
    return (["~"] + parts.dropFirst(3)).joined(separator: "/")
}

extension View {
    /// Adds a search field only to lists long enough to need one.
    @ViewBuilder
    func searchable(text: Binding<String>, prompt: String, when condition: Bool) -> some View {
        if condition {
            searchable(text: text, prompt: Text(prompt))
        } else {
            self
        }
    }
}
