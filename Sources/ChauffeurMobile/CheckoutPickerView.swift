import SwiftUI
import ChauffeurRemoteProtocol

/// New session, third step: the repository's main checkout and worktrees, or a new worktree.
struct CheckoutPickerView: View {
    var model: MobileAppModel
    let projectID: UUID
    let folderID: UUID
    @State private var query = ""

    private var project: ProjectSummary? { model.inventory?.project(projectID) }
    private var folder: FolderSummary? { project?.folders.first { $0.id == folderID } }

    var body: some View {
        Group {
            if let project, let folder {
                List {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        checkoutSections(folder)
                    } else {
                        LaunchSearchSections(model: model, search: LaunchSearch(query: query, projects: [Self.scoped(project, to: folder)]),
                                             query: query, showsProject: false)
                    }
                }
                .searchable(text: $query, prompt: "Branches and worktrees", when: folder.checkouts.count > 6)
                .navigationTitle(folder.name)
            } else {
                ContentUnavailableView("Repository unavailable", systemImage: "folder.badge.questionmark",
                                       description: Text("It is no longer in this project on your Mac."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The project with only this repository, so the search stays inside it.
    private static func scoped(_ project: ProjectSummary, to folder: FolderSummary) -> ProjectSummary {
        var project = project
        project.folders = [folder]
        return project
    }

    @ViewBuilder
    private func checkoutSections(_ folder: FolderSummary) -> some View {
        Section {
            if folder.checkouts.isEmpty {
                if folder.inventoryReady {
                    Text("No checkouts found.").foregroundStyle(.secondary)
                } else {
                    HStack {
                        ProgressView()
                        Text("Loading checkouts…").foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(folder.checkouts) { checkout in
                let location = LaunchLocation(projectID: projectID, folderID: folder.id, checkout: .existing(path: checkout.path))
                NavigationLink(value: MobileRoute.launch(location)) {
                    HStack(alignment: .firstTextBaseline) {
                        CheckoutLabel(kind: checkout.kind, branch: checkout.branch, path: checkout.path, isRepository: folder.isRepository,
                                      unavailable: checkout.availability != .available, note: checkout.note)
                        Spacer(minLength: 8)
                        LiveSessionsBadge(count: model.liveSessionCount(checkoutPath: checkout.path))
                    }
                }
                .disabled(checkout.availability != .available)
                .accessibilityIdentifier("new-session-checkout")
            }
        } header: {
            Text(folder.isRepository ? "Checkouts" : "Folder")
        } footer: {
            if !folder.isRepository {
                Text("Non-Git folders support existing-folder launches only.")
            }
        }

        if folder.isRepository {
            Section {
                NavigationLink(value: MobileRoute.newWorktree(projectID: projectID, folderID: folder.id)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New worktree")
                            Text("A new branch, or one not checked out yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "plus.square.on.square")
                    }
                }
                .accessibilityIdentifier("new-session-new-worktree")
            } footer: {
                Text("The Mac creates a managed worktree, then launches in it.")
            }
        }
    }
}

#Preview {
    let model = MobileAppModel.preview()
    let project = model.inventory!.projects[0]
    return NavigationStack {
        CheckoutPickerView(model: model, projectID: project.id, folderID: project.folders[0].id)
    }
}
