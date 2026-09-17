import SwiftUI
import ChauffeurCore

struct WorktreesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let worktreeCreated: (Worktree) -> Void
    @State private var folderID: UUID?
    @State private var branch = ""
    @State private var baseRef = "HEAD"
    @State private var destination = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var removing: CheckoutRow?
    @State private var deletionPreview = WorktreeDeletionPreview(hasChanges: false)
    @State private var creation: WorktreeCreationRequest?
    init(project: Project, initialFolderID: UUID? = nil, worktreeCreated: @escaping (Worktree) -> Void = { _ in }) {
        self.project = project
        self.worktreeCreated = worktreeCreated
        _folderID = State(initialValue: project.folders.first { $0.id == initialFolderID && $0.registered }?.id
            ?? project.folders.first(where: \.registered)?.id)
    }
    private var currentProject: Project { model.project(project.id) ?? project }
    private var folder: ProjectFolder? { currentProject.folders.first { $0.id == folderID } }
    private var observation: RepositoryInventory? {
        guard let folder else { return nil }
        return model.snapshot.repositoryInventories?.observation(for: folder.canonicalPath)
    }
    /// No observation yet means the folder has not been scanned, not that it has no worktrees.
    private var inventoryPending: Bool { folder != nil && observation == nil && model.online }
    private var rows: [CheckoutRow] {
        guard let folder else { return [] }
        return CheckoutRows.rows(folder: folder, project: currentProject, records: model.snapshot.store.worktrees.map(\.value), inventory: observation, sessions: model.sessions(in: project.id))
    }
    private var worktreeRows: [CheckoutRow] { rows.filter { !$0.isMain } }
    private var stale: [GitWorktree] { folder.map { CheckoutRows.staleEntries(folder: $0, inventory: observation, rows: rows) } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Repository Worktrees").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy).accessibilityIdentifier("worktrees.done") }
            HStack {
                Picker("Repository", selection: $folderID) {
                    Text("Choose a repository").tag(UUID?.none)
                    ForEach(currentProject.folders.filter(\.registered)) { folder in Text(folder.name).tag(Optional(folder.id)) }
                }.disabled(busy).accessibilityIdentifier("worktrees.repository")
                Button("Refresh Git Inventory") { refresh() }.disabled(folder == nil || busy).accessibilityIdentifier("worktrees.refresh")
            }
            Text(inventoryPending ? "Loading Git inventory…" : "\(worktreeRows.count) worktrees" + (stale.isEmpty ? "" : " · \(stale.count) stale Git entries")).font(.caption).foregroundStyle(.secondary)
            ScrollView {
              VStack(alignment: .leading, spacing: 0) {
                ForEach(worktreeRows) { row in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.title).fontWeight(.medium)
                            Text(row.path).font(.caption).textSelection(.enabled)
                            Text(([row.managed ? "Chauffeur managed" : "External", row.statusLabel ?? "Available"] + row.gitStatusLabels).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("worktrees.status.\(row.path)")
                            if observation?.entries.first(where: { $0.path == row.path })?.locked == true { Text("Locked in Git").font(.caption).foregroundStyle(.secondary) }
                            if !row.sessions.isEmpty {
                                Text("Sessions: \(row.sessions.map(\.title).joined(separator: ", "))").font(.caption).lineLimit(2).help(row.sessions.map(\.title).joined(separator: ", "))
                            }
                        }
                        Spacer()
                        Button("Delete…") { prepareDeletion(row) }.disabled(busy || !row.liveSessions.isEmpty)
                            .help(row.liveSessions.isEmpty ? "Delete the checkout and its session history" : "Stop its live sessions first")
                            .accessibilityIdentifier("worktrees.remove.\(row.worktreeID?.uuidString ?? row.path)")
                    }.padding(10)
                    Divider()
                }
                if !stale.isEmpty {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Stale Git entries").fontWeight(.medium)
                            ForEach(stale) { entry in Text(entry.path).font(.caption).foregroundStyle(.secondary) }
                            Text("Git still lists these worktrees, but their directories are gone and no sessions refer to them.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Prune") { prune() }.disabled(busy).accessibilityIdentifier("worktrees.prune")
                    }.padding(10)
                    Divider()
                }
                if inventoryPending {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading Git inventory…").foregroundStyle(.secondary) }.padding(16).accessibilityIdentifier("worktrees.loading")
                } else if worktreeRows.isEmpty && stale.isEmpty { Text("No worktrees for this repository.").foregroundStyle(.secondary).padding(16) }
              }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
                .background(PersistentScrollbars())
            }.scrollIndicators(.visible).frame(height: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            GroupBox("Create Worktree") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { TextField("New branch name", text: $branch).accessibilityIdentifier("worktrees.branch"); TextField("Base ref", text: $baseRef).frame(width: 180).accessibilityIdentifier("worktrees.base") }.disabled(busy)
                    if !destination.isEmpty { Text(destination).font(.system(.caption, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("worktrees.destination") }
                    HStack { Text("Created checkouts remain reusable if an agent launch fails.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Create Worktree") { create() }.disabled(busy || folderID == nil || branch.isEmpty || baseRef.isEmpty).accessibilityIdentifier("worktrees.create") }
                }.padding(8)
            }
            if busy { ProgressView().controlSize(.small) }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled).lineLimit(3).help(failure).accessibilityIdentifier("worktrees.error") }
            if let observation {
                if let error = observation.error { Text(error.errorDescription ?? "Git inventory unavailable").foregroundStyle(.red).font(.caption) }
                else if observation.status == .notRepository { Text("This folder is not a Git repository.").font(.caption).foregroundStyle(.secondary) }
                else { Text("Git inventory checked \(observation.observedAt, style: .relative) ago. Refreshes while the background service is running.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Deleting a worktree removes its checkout and finished session history. Stop live sessions first. You will be warned before local changes are discarded. Branches with no unique commits are also deleted.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 760).interactiveDismissDisabled(busy)
            .onAppear { refresh() }
            .onChange(of: folderID) { _, _ in refresh() }
            .task(id: "\(folderID?.uuidString ?? ""):\(branch)") {
                destination = ""
                guard let folderID, !branch.isEmpty else { return }
                let proposedBranch = branch
                try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }
                if let value = try? await model.call("previewWorktree", .object(["projectID": .string(project.id.uuidString), "folderID": .string(folderID.uuidString), "branch": .string(proposedBranch)])), !Task.isCancelled, self.folderID == folderID, branch == proposedBranch { destination = value["path"].string ?? "" }
            }
            .confirmationDialog("Delete \(removing?.title ?? "worktree")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Delete Worktree", role: .destructive) {
                    if let removing {
                        let discardChanges = deletionPreview.hasChanges
                        run { _ = try await model.call("deleteWorktree", .object(["projectID": .string(project.id.uuidString), "folderID": .string(removing.folderID.uuidString), "path": .string(removing.path), "discardChanges": .bool(discardChanges)])) }
                    }
                    removing = nil
                }
            } message: {
                if let removing {
                    Text(deletionPreview.warningText + (removing.finished ? "The checkout is already gone." : "Removes \(removing.path) from disk. Branches with no unique commits are also deleted.")
                         + (removing.sessions.isEmpty ? "" : "\n\(removing.sessions.count) finished session\(removing.sessions.count == 1 ? "" : "s") and their terminal history are deleted."))
                }
            }
    }
    private func prepareDeletion(_ row: CheckoutRow) {
        run {
            let preview = try await model.call("previewWorktreeDeletion", .object(["projectID": .string(project.id.uuidString), "folderID": .string(row.folderID.uuidString), "path": .string(row.path)]))
            deletionPreview = try preview.decode(WorktreeDeletionPreview.self)
            removing = row
        }
    }
    private func refresh() {
        guard folder != nil else { return }
        run { _ = try await model.call("refreshWorktrees") }
    }
    private func create() {
        guard !busy, let folderID else { return }
        if creation?.folderID != folderID || creation?.branch != branch || creation?.baseRef != baseRef {
            creation = WorktreeCreationRequest(projectID: project.id, folderID: folderID, branch: branch, baseRef: baseRef)
        }
        guard let request = creation else { return }
        run {
            let created = try await model.call("createWorktree", .from(request)).decode(Stored<Worktree>.self).value
            worktreeCreated(created)
            creation = nil; branch = ""
            _ = try await model.call("refreshWorktrees")
        }
    }
    private func prune() {
        guard let folderID else { return }
        run { _ = try await model.call("pruneWorktrees", .object(["projectID": .string(project.id.uuidString), "folderID": .string(folderID.uuidString)])) }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil
        Task {
            defer { busy = false }
            do { try await operation(); try await model.refresh() }
            catch { failure = error.localizedDescription; try? await model.refresh() }
        }
    }
}
