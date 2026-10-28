import SwiftUI
import ChauffeurRemoteProtocol

/// 04 / Location: project → repository/folder → checkout (main, worktrees, or a new worktree).
struct LocationView: View {
    var model: MobileAppModel
    var preselectedProjectID: UUID?

    @State private var projectID: UUID?
    @State private var folderID: UUID?
    @State private var checkout: LaunchLocation.Checkout?

    private var inventory: InventorySnapshot? { model.inventory }

    private var projects: [ProjectSummary] {
        inventory?.projects.filter { !$0.archived } ?? []
    }

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
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if let project {
                Section("Repository / folder") {
                    // Nested in the Mac sidebar's groups, which the phone only shows.
                    ForEach(OutlineRow.rows(project.folderOutline)) { row in
                        switch row.item {
                        case .group(let group, _):
                            Label(group.name, systemImage: "rectangle.stack")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, CGFloat(row.depth) * 20)
                                .accessibilityAddTraits(.isHeader)
                        case .folder(let folder):
                            SelectableRow(isSelected: folderID == folder.id) {
                                folderID = folder.id
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(folder.name)
                                        Text(folder.availability == .available ? folder.path : "\(folder.path) · unavailable")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "folder")
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * 20)
                        }
                    }
                }
            }

            if let folder {
                Section {
                    ForEach(folder.checkouts) { existing in
                        SelectableRow(isSelected: checkout == .existing(path: existing.path)) {
                            checkout = .existing(path: existing.path)
                        } label: {
                            CheckoutLabel(kind: existing.kind, branch: existing.branch, path: existing.path, isRepository: folder.isRepository,
                                          unavailable: existing.availability != .available)
                        }
                        .disabled(existing.availability != .available)
                    }
                    if folder.isRepository {
                        SelectableRow(isSelected: checkout == .newWorktree) {
                            checkout = .newWorktree
                        } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text("New worktree…")
                                    Text("Branch and base ref on the next step")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                } header: {
                    Text("Checkout")
                } footer: {
                    Text(folder.isRepository
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
                .accessibilityIdentifier("location-continue")
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
        projectID = preselectedProjectID ?? projects.first?.id
        folderID = project?.folders.first?.id
        selectDefaultCheckout()
    }

    private func selectDefaultCheckout() {
        let available = folder?.checkouts.filter { $0.availability == .available } ?? []
        let main = available.first(where: { $0.kind == .main }) ?? available.first
        checkout = main.map { .existing(path: $0.path) }
    }
}

/// A folder outline entry with how deeply it is nested.
private struct OutlineRow: Identifiable {
    let item: FolderOutlineItem
    let depth: Int

    var id: UUID { item.id }

    static func rows(_ items: [FolderOutlineItem], depth: Int = 0) -> [OutlineRow] {
        items.flatMap { item -> [OutlineRow] in
            switch item {
            case .folder: [OutlineRow(item: item, depth: depth)]
            case .group(_, let items): [OutlineRow(item: item, depth: depth)] + rows(items, depth: depth + 1)
            }
        }
    }
}

private struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    var onSelect: () -> Void
    @ViewBuilder var label: Content

    var body: some View {
        Button(action: onSelect) {
            HStack {
                label
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    NavigationStack {
        LocationView(model: .preview())
    }
}
