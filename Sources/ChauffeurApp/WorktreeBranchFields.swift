import SwiftUI
import ChauffeurCore

/// Shared by agent launch and the repository's standalone worktree creator.
struct WorktreeBranchFields: View {
    @EnvironmentObject private var model: AppModel
    let projectID: UUID
    let folderID: UUID?
    @Binding var reuseExistingBranch: Bool
    @Binding var branch: String
    @Binding var baseRef: String
    var accessibilityPrefix = "session"
    @State private var choosingBranch = false
    @State private var query = ""
    @State private var refs: [GitRef]?
    @State private var failure: String?
    @FocusState private var branchFocused: Bool

    private var occupied: [String: String] {
        guard let folder = model.project(projectID)?.folders.first(where: { $0.id == folderID }),
              let inventory = model.snapshot.repositoryInventories?.observation(for: folder.canonicalPath) else { return [:] }
        return Dictionary(inventory.entries.filter { !$0.branch.isEmpty }.map { ($0.branch, $0.path) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("Branch", selection: $reuseExistingBranch) {
                Text("New branch").tag(false)
                Text("Existing branch").tag(true)
            }.labelsHidden()
                .frame(width: 145)
                .accessibilityIdentifier(accessibilityPrefix + ".branch-mode")
            if reuseExistingBranch {
                Group {
                    Button(branch.isEmpty ? "Choose a branch…" : branch) {
                        query = ""
                        choosingBranch = true
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(accessibilityPrefix + ".existing-branch")
                    .popover(isPresented: $choosingBranch) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Search local branches", text: $query)
                            if let failure {
                                Text(failure).foregroundStyle(.red)
                            } else if let refs {
                                let matches = GitRef.filtered(refs, query: query)
                                if matches.isEmpty { Text("No matching local branches.").foregroundStyle(.secondary) }
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(matches) { ref in
                                            let path = occupied[ref.name]
                                            Button {
                                                branch = ref.name
                                                choosingBranch = false
                                            } label: {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(ref.name)
                                                    if let path { Text("Checked out at " + path).font(.caption).textSelection(.enabled) }
                                                    else if ref.isCheckedOutInWorktree || ref.isHEAD { Text("Already checked out").font(.caption) }
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .disabled(path != nil || ref.isCheckedOutInWorktree || ref.isHEAD)
                                        }
                                    }
                                }.frame(maxHeight: 280)
                            } else { ProgressView() }
                        }.padding(16).frame(width: 440)
                            .task {
                                refs = nil; failure = nil
                                guard let folderID else { return }
                                do {
                                    let snapshot = try await model.call("listGitRefs", .object(["projectID": .string(projectID.uuidString), "folderID": .string(folderID.uuidString)])).decode(GitRefSnapshot.self)
                                    guard !Task.isCancelled else { return }
                                    refs = snapshot.refs.filter { $0.kind == .local }
                                } catch { failure = error.localizedDescription }
                            }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Branch name", text: $branch).labelsHidden().autocorrectionDisabled()
                        .accessibilityIdentifier(accessibilityPrefix + ".branch")
                        .focused($branchFocused)
                        .task { await Task.yield(); if !Task.isCancelled { branchFocused = true } }
                    Text("from").foregroundStyle(.secondary)
                    if let folderID { RefPicker(projectID: projectID, folderID: folderID, selection: $baseRef) }
                }
            }
        }
    }
}

struct WorktreeDestinationLabel: View {
    let path: String
    var accessibilityIdentifier = "session.destination"
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Worktree destination").font(.caption).foregroundStyle(.secondary)
            Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}
