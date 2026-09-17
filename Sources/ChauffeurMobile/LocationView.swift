import SwiftUI

/// 04 / Location: project → repository/folder → checkout (main, worktrees, or a new worktree).
struct LocationView: View {
    var model: MobileAppModel
    var preselectedProjectID: UUID?

    @State private var projectID: UUID?
    @State private var folderID: UUID?
    @State private var checkout: LaunchLocation.Checkout?

    private var inventory: InventorySnapshot? { model.inventory }

    private var project: ProjectSummary? {
        projectID.flatMap { inventory?.project($0) }
    }

    private var folder: FolderSummary? {
        folderID.flatMap { inventory?.folder($0) }
    }

    private var location: LaunchLocation? {
        guard let projectID, let folderID, let checkout else { return nil }
        return LaunchLocation(projectID: projectID, folderID: folderID, checkout: checkout)
    }

    var body: some View {
        Form {
            Section("Project") {
                Picker("Project", selection: $projectID) {
                    ForEach(inventory?.projects ?? []) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if let project {
                Section("Repository / folder") {
                    Picker("Repository / folder", selection: $folderID) {
                        ForEach(project.folders) { folder in
                            VStack(alignment: .leading) {
                                Text(folder.name)
                                Text(folder.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(folder.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            if let folder {
                Section {
                    ForEach(folder.checkouts) { existing in
                        CheckoutRow(
                            title: existing.kind == .main ? "Main checkout" : "Existing",
                            subtitle: existing.branch,
                            systemImage: existing.kind == .main ? "arrow.triangle.branch" : "arrow.triangle.pull",
                            isSelected: checkout == .existing(existing.id)
                        ) {
                            checkout = .existing(existing.id)
                        }
                    }
                    if folder.isGitRepository {
                        CheckoutRow(
                            title: "New worktree…",
                            subtitle: "Branch and base ref on the next step",
                            systemImage: "plus",
                            isSelected: checkout == .newWorktree
                        ) {
                            checkout = .newWorktree
                        }
                    }
                } header: {
                    Text("Checkout")
                } footer: {
                    Text(folder.isGitRepository
                         ? "Use a checkout already available on your Mac, or create a managed worktree."
                         : "Non-Git folders support existing-folder launches only.")
                }
            }
        }
        .navigationTitle("New session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    model.path.removeLast()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") {
                    if let location {
                        model.path.append(.launch(location))
                    }
                }
                .disabled(location == nil)
            }
        }
        .onAppear(perform: applyDefaults)
        .onChange(of: projectID) { _, _ in
            folderID = project?.folders.first?.id
            selectDefaultCheckout()
        }
        .onChange(of: folderID) { _, _ in
            selectDefaultCheckout()
        }
    }

    private func applyDefaults() {
        guard projectID == nil else { return }
        projectID = preselectedProjectID ?? inventory?.projects.first?.id
        folderID = project?.folders.first?.id
        selectDefaultCheckout()
    }

    private func selectDefaultCheckout() {
        let main = folder?.checkouts.first(where: { $0.kind == .main }) ?? folder?.checkouts.first
        checkout = main.map { .existing($0.id) }
    }
}

private struct CheckoutRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        LocationView(model: .preview())
    }
}
