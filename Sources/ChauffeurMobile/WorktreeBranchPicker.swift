import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// What a branch is picked for: an existing branch to check out in the new worktree, which
/// must not be checked out anywhere yet, or the starting point of a new branch, which may be.
enum WorktreeBranchPurpose {
    case existingBranch
    case startingPoint

    var title: String {
        switch self {
        case .existingBranch: "Existing branch"
        case .startingPoint: "Starting point"
        }
    }
}

/// A row opening a searchable picker of the repository's existing local branches.
struct WorktreeBranchPicker: View {
    let model: MobileAppModel
    let projectID: UUID
    let folderID: UUID
    @Binding var selection: String
    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            LabeledContent("Existing branch", value: selection.isEmpty ? "Choose a branch…" : selection)
        }
        .accessibilityIdentifier("launch-existing-branch")
        .sheet(isPresented: $presented) {
            WorktreeBranchPickerSheet(model: model, projectID: projectID, folderID: folderID, purpose: .existingBranch, selection: $selection)
        }
    }
}

/// A searchable local-branch picker backed by the connected Mac.
struct WorktreeBranchPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: MobileAppModel
    let projectID: UUID
    let folderID: UUID
    let purpose: WorktreeBranchPurpose
    @Binding var selection: String
    @State private var branches: [WorktreeBranchOption]?
    @State private var query = ""
    @State private var failure: String?
    @State private var attempt = 0

    private var matches: [WorktreeBranchOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (branches ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.secondary)
                        Button("Retry") { attempt += 1 }
                    }
                } else if branches == nil {
                    ProgressView("Loading branches…")
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(matches) { branch in
                        let unavailable = purpose == .existingBranch && branch.isCheckedOut
                        Button {
                            selection = branch.name
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(branch.name).foregroundStyle(unavailable ? .secondary : .primary)
                                    if let path = branch.checkoutPath {
                                        Text("Checked out at " + path).font(.caption).foregroundStyle(.secondary)
                                    } else if branch.isCheckedOut {
                                        Text("Already checked out").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if branch.name == selection { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(unavailable)
                    }
                }
            }
            .navigationTitle(purpose.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search local branches")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: attempt) {
                branches = nil; failure = nil
                do {
                    let result = try await model.worktreeBranches(projectID: projectID, folderID: folderID)
                    guard !Task.isCancelled else { return }
                    branches = result
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = (error as? RemoteClientError)?.userMessage ?? error.localizedDescription
                }
            }
        }
    }
}
