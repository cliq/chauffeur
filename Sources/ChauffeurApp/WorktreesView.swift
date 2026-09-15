import SwiftUI
import ChauffeurCore

struct WorktreesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var folderID: UUID?
    @State private var branch = ""
    @State private var baseRef = "HEAD"
    @State private var destination = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var removing: Worktree?
    private var currentProject: Project { model.project(project.id) ?? project }
    private var folder: ProjectFolder? { currentProject.folders.first { $0.id == folderID } }
    private var observation: RepositoryInventory? {
        guard let folder else { return nil }
        return model.snapshot.repositoryInventories?.first { $0.sourcePath == folder.canonicalPath || $0.sourcePaths?.contains(folder.canonicalPath) == true }
    }
    private var inventory: [GitWorktree] { observation?.entries ?? [] }
    private var records: [Worktree] { model.snapshot.store.worktrees.map(\.value).filter { $0.projectID == project.id && $0.folderID == folderID && $0.registered } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Repository Worktrees").font(.title2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            HStack {
                Picker("Repository", selection: $folderID) {
                    Text("Choose a repository").tag(UUID?.none)
                    ForEach(currentProject.folders.filter(\.registered)) { folder in Text(folder.name).tag(Optional(folder.id)) }
                }
                Button("Refresh Git Inventory") { refresh() }.disabled(folder == nil || busy)
            }
            List {
                ForEach(records) { tree in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(tree.branch.isEmpty ? "Detached HEAD" : tree.branch).fontWeight(.medium)
                            Text(tree.path).font(.caption).textSelection(.enabled)
                            Text("\(tree.managed ? "Chauffeur managed" : "External") · \(tree.availability.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
                            if inventory.first(where: { $0.path == tree.path })?.locked == true { Text("Locked in Git").font(.caption).foregroundStyle(.secondary) }
                            let associated = model.snapshot.sessions.filter { session in
                                session.worktreeID == tree.id || session.launch.workingDirectory == tree.path || session.launch.additionalPaths.contains(tree.path)
                                    || tree.gitIdentity.map { (session.launch.gitWorktreeIdentities ?? []).contains($0) } == true
                            }
                            if !associated.isEmpty { Text("Sessions: \(associated.map(\.title).joined(separator: ", "))").font(.caption) }
                        }
                        Spacer()
                        Button(tree.managed ? "Remove…" : "Unregister") { removing = tree }.disabled(busy)
                    }.padding(.vertical, 6)
                }
                ForEach(inventory.filter { entry in !records.contains { $0.path == entry.path } }) { entry in
                    HStack {
                        VStack(alignment: .leading) { Text(entry.branch.isEmpty ? "Detached HEAD" : entry.branch); Text(entry.path).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Register") { register(entry) }.disabled(busy || entry.availability != .available)
                    }
                }
            }.frame(height: 240)
            GroupBox("Create Worktree") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { TextField("New branch name", text: $branch); TextField("Base ref", text: $baseRef).frame(width: 180) }
                    if !destination.isEmpty { Text(destination).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    HStack { Text("Created checkouts remain reusable if an agent launch fails.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Create Worktree") { create() }.disabled(busy || folderID == nil || branch.isEmpty || baseRef.isEmpty) }
                }.padding(8)
            }
            if busy { ProgressView().controlSize(.small) }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            if let observation {
                if let error = observation.error { Text(error.errorDescription ?? "Git inventory unavailable").foregroundStyle(.red).font(.caption) }
                else if observation.status == .notRepository { Text("This folder is not a Git repository.").font(.caption).foregroundStyle(.secondary) }
                else { Text("Git inventory checked \(observation.observedAt, style: .relative) ago. Refreshes while the background service is running.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Removal requires a clean app-managed worktree with no live sessions. Branches are preserved. External worktrees are only unregistered.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 760)
            .onAppear { folderID = currentProject.folders.first(where: \.registered)?.id }
            .onChange(of: folderID) { _, _ in refresh() }
            .task(id: "\(folderID?.uuidString ?? ""):\(branch)") {
                guard let folderID, !branch.isEmpty else { destination = ""; return }
                try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }
                if let value = try? await model.call("previewWorktree", .object(["projectID": .string(project.id.uuidString), "folderID": .string(folderID.uuidString), "branch": .string(branch)])) { destination = value["path"].string ?? "" }
            }
            .confirmationDialog(removing?.managed == true ? "Remove this worktree?" : "Unregister this worktree?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button(removing?.managed == true ? "Remove Worktree" : "Unregister", role: .destructive) {
                    if let removing { model.perform { _ = try await model.call("removeWorktree", .object(["worktreeID": .string(removing.id.uuidString)])); refresh() } }
                    removing = nil
                }
            } message: { Text("\(removing?.branch ?? "")\n\(removing?.path ?? "")") }
    }
    private func refresh() {
        guard folder != nil else { return }
        busy = true; failure = nil
        Task { defer { busy = false }; do { _ = try await model.call("refreshWorktrees"); try await model.refresh() } catch { failure = error.localizedDescription } }
    }
    private func create() {
        guard let folderID else { return }; busy = true; failure = nil
        Task {
            do { _ = try await model.call("createWorktree", .object(["projectID": .string(project.id.uuidString), "folderID": .string(folderID.uuidString), "branch": .string(branch), "baseRef": .string(baseRef)])); try await model.refresh(); branch = ""; busy = false; refresh() }
            catch { failure = error.localizedDescription; busy = false }
        }
    }
    private func register(_ entry: GitWorktree) {
        guard let folderID else { return }
        model.perform { _ = try await model.call("registerWorktree", .object(["projectID": .string(project.id.uuidString), "folderID": .string(folderID.uuidString), "path": .string(entry.path)])) }
    }
}
