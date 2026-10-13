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
    @State private var fetchedAt: Date?
    @State private var fetching = false
    @State private var fetchFailure: String?
    @State private var listHeight: CGFloat = 0
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
                            HStack(spacing: 8) {
                                TextField("Search branches", text: $query)
                                if fetching { ProgressView().controlSize(.small) }
                                Button("Fetch") { Task { await loadRefs(fetching: true) } }
                                    .disabled(fetching || refs == nil)
                                    .help(fetchStatus)
                                    .accessibilityIdentifier(accessibilityPrefix + ".fetch-branches")
                            }
                            if let fetchFailure { Text(fetchFailure).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            if let failure {
                                Text(failure).foregroundStyle(.red)
                            } else if let refs {
                                let matches = GitRef.filtered(refs, query: query, name: Self.localName)
                                if matches.isEmpty { Text("No matching branches.").foregroundStyle(.secondary) }
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(matches) { ref in
                                            let name = Self.localName(ref)
                                            let path = occupied[name]
                                            Button {
                                                branch = name
                                                choosingBranch = false
                                            } label: {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(name)
                                                    if ref.kind == .remote { Text("Creates a local branch tracking " + ref.name).font(.caption).foregroundStyle(.secondary) }
                                                    else if let path { Text("Checked out at " + path).font(.caption).textSelection(.enabled) }
                                                    else if ref.isCheckedOutInWorktree || ref.isHEAD { Text("Already checked out").font(.caption) }
                                                }.frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .disabled(path != nil || ref.isCheckedOutInWorktree || ref.isHEAD)
                                        }
                                    }
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                                }
                                // A popover sizes to ideal height, which collapses a scroll view; fit the rows instead.
                                .frame(height: min(listHeight, 280))
                            } else { ProgressView() }
                        }.padding(16).frame(width: 440)
                            .task {
                                refs = nil; failure = nil; fetchFailure = nil
                                await loadRefs(fetching: false)
                            }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Branch name", text: $branch).labelsHidden().autocorrectionDisabled()
                        .accessibilityIdentifier(accessibilityPrefix + ".branch")
                        .focused($branchFocused)
                        .task { await Task.yield(); if !Task.isCancelled { branchFocused = true } }
                        .task(id: branch) { await resolvePastedTicket() }
                    Text("from").foregroundStyle(.secondary)
                    if let folderID { RefPicker(projectID: projectID, folderID: folderID, selection: $baseRef) }
                }
            }
        }
    }
}

extension WorktreeBranchFields {
    /// Local branches, plus remote branches under the local name a worktree would
    /// check them out as when no local branch has it. `origin` wins a name several remotes share.
    static func branchChoices(_ refs: [GitRef]) -> [GitRef] {
        let locals = refs.filter { $0.kind == .local }
        var taken = Set(locals.map(\.name))
        let remotes = refs.filter { $0.kind == .remote && !localName($0).isEmpty }
            .sorted { ($0.name.hasPrefix("origin/") ? 0 : 1, $0.name) < ($1.name.hasPrefix("origin/") ? 0 : 1, $1.name) }
            .filter { taken.insert(localName($0)).inserted }
        return locals + remotes
    }

    private var fetchStatus: String {
        guard let fetchedAt else { return "Fetch branches from all remotes. Not fetched yet." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Fetch branches from all remotes. Fetched " + formatter.localizedString(for: fetchedAt, relativeTo: Date()) + "."
    }

    /// Lists the repository's branches, fetching every remote first when asked.
    /// A failed fetch keeps the current list.
    private func loadRefs(fetching: Bool) async {
        guard let folderID else { return }
        if fetching { self.fetching = true; fetchFailure = nil }
        defer { if fetching { self.fetching = false } }
        do {
            let snapshot = try await model.call(fetching ? "fetchGitRefs" : "listGitRefs", .object(["projectID": .string(projectID.uuidString), "folderID": .string(folderID.uuidString)]),
                                          responseTimeout: fetching ? 130 : 30).decode(GitRefSnapshot.self)
            guard !Task.isCancelled else { return }
            refs = Self.branchChoices(snapshot.refs)
            fetchedAt = snapshot.fetchedAt
        } catch {
            if fetching { fetchFailure = error.localizedDescription } else { failure = error.localizedDescription }
        }
    }

    /// A remote branch's name without its remote, as the runtime checks it out.
    static func localName(_ ref: GitRef) -> String {
        ref.kind == .remote ? ref.name.split(separator: "/", maxSplits: 1).dropFirst().joined() : ref.name
    }

    /// A pasted ticket link becomes the repository's branch name for it. Keys are left as typed,
    /// since a key typed by hand would match before it is finished.
    private func resolvePastedTicket() async {
        let text = branch
        guard let folderID, model.online, text.contains("://") else { return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let ticket = try? await model.resolveTicket(projectID: projectID, folderID: folderID, text: text),
              !Task.isCancelled, branch == text, !reuseExistingBranch, ticket.url != nil else { return }
        branch = ticket.branch
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
