import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// A searchable local-branch picker backed by the connected Mac.
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
            WorktreeBranchPickerSheet(model: model, projectID: projectID, folderID: folderID, selection: $selection)
        }
    }
}

private struct WorktreeBranchPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: MobileAppModel
    let projectID: UUID
    let folderID: UUID
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
                        Button {
                            selection = branch.name
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(branch.name).foregroundStyle(branch.isCheckedOut ? .secondary : .primary)
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
                        .disabled(branch.isCheckedOut)
                    }
                }
            }
            .navigationTitle("Existing branch")
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
