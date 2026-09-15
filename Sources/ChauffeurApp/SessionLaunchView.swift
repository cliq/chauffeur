import SwiftUI
import AppKit
import ChauffeurCore

struct SessionLaunchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let initialGroupID: UUID?
    let initialFolderID: UUID?
    var startsInNewWorktree = false
    let completion: (UUID) -> Void
    private enum Checkout: Hashable { case repository, existing(UUID), newWorktree }
    @StateObject private var operation = SessionLaunchOperation()
    @State private var title = ""
    @State private var task = ""
    @State private var groupID: UUID?
    @State private var presetID: UUID?
    @State private var folderID: UUID?
    @State private var checkout = Checkout.repository
    @State private var branch = ""
    @State private var baseRef = "HEAD"
    @State private var destination = ""
    @State private var additional = Set<UUID>()
    @State private var shared = false
    @State private var coordination = true
    private var currentProject: Project { model.project(project.id) ?? project }
    private var presets: [AgentPreset] { model.presets.filter { $0.setID == currentProject.presetSetID && !$0.archived } }
    private var preset: AgentPreset? { presets.first { $0.id == presetID } }
    private var folder: ProjectFolder? { currentProject.folders.first { $0.id == folderID && $0.registered } }
    private var worktrees: [Worktree] {
        let records = model.snapshot.store.worktrees.map(\.value)
        var result = records.filter { $0.projectID == project.id && $0.folderID == folderID && $0.registered }
        // Bridge the creation response until the next snapshot arrives, without
        // reviving a checkout that a later snapshot explicitly unregisters.
        if let created = operation.createdWorktree, created.folderID == folderID, !records.contains(where: { $0.id == created.id }) { result.append(created) }
        return result
    }
    private var worktreeID: UUID? { if case .existing(let id) = checkout { return id }; return nil }
    private var primaryPath: String {
        if checkout == .newWorktree { return destination }
        return worktrees.first { $0.id == worktreeID }?.path ?? folder?.canonicalPath ?? ""
    }
    private var primaryGitIdentity: UUID? {
        worktrees.first { $0.id == worktreeID }?.gitIdentity
            ?? model.snapshot.repositoryInventories?.flatMap(\.entries).first { $0.path == primaryPath }?.gitIdentity
    }
    private var sharing: [Session] {
        guard checkout != .newWorktree else { return [] }
        return model.snapshot.sessions.filter { peer in
            peer.state.isLive && (peer.launch.workingDirectory == primaryPath || primaryGitIdentity.map { (peer.launch.gitWorktreeIdentities ?? []).contains($0) } == true)
        }
    }
    private var canLaunch: Bool {
        !operation.isBusy && model.online && !currentProject.archived && preset != nil && folder != nil && groupID != nil
            && (sharing.isEmpty || shared) && (checkout != .newWorktree || (!branch.isEmpty && !baseRef.isEmpty))
            && (worktreeID == nil || worktrees.contains { $0.id == worktreeID && $0.availability == .available })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(checkout == .newWorktree ? "New Worktree & Session" : "New Session").font(.title2).padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sessionFields
                    checkoutFields
                    if !primaryPath.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(checkout == .newWorktree ? "Worktree destination" : "Working directory").font(.caption).foregroundStyle(.secondary)
                            Text(primaryPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let created = operation.createdWorktree, worktreeID == created.id {
                        Label("Worktree created. It stays available if the agent cannot start.", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !sharing.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("This checkout is in use", systemImage: "person.2.fill").fontWeight(.medium)
                            ForEach(sharing) { session in Text("\(model.project(session.projectID)?.name ?? "Project") · \(session.title)").font(.caption) }
                            Toggle("Share this checkout with these sessions", isOn: $shared)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    additionalFolders
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Initial task (optional)").font(.headline)
                        ArgumentEditor(text: $task, accessibilityLabel: "Initial task").frame(height: 84)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Enable Chauffeur messaging and delegation", isOn: $coordination)
                        Text(coordination ? "CLI integration is under compatibility validation. Profile names identify configuration directories; they do not verify an account." : "Basic terminal mode: Chauffeur communication and semantic status signals are unavailable.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(24).padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
                    .background(PersistentScrollbars()).disabled(operation.isBusy)
            }.scrollIndicators(.visible)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let failure = operation.failure { Text("Last attempt: \(failure)").foregroundStyle(.red).font(.callout).lineLimit(3).help(failure).textSelection(.enabled) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(operation.isBusy)
                    Spacer()
                    if operation.canRetry && !operation.isBusy {
                        Button("Check Previous Attempt") { launch(retry: true) }.disabled(!model.online)
                            .help("Recover the result of the previous attempt. Edited fields apply when you launch a new attempt.")
                    }
                    if operation.isBusy { ProgressView().controlSize(.small) }
                    Button(operation.progress ?? (checkout == .newWorktree ? "Create & Launch" : "Launch Session")) { launch(retry: false) }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canLaunch)
                }
            }.padding(20)
        }.frame(width: 680, height: max(420, min(650, (NSScreen.main?.visibleFrame.height ?? 800) - 100)))
            .interactiveDismissDisabled(operation.isBusy)
            .onAppear {
                groupID = currentProject.groups.first { $0.id == initialGroupID && !$0.archived }?.id ?? currentProject.groups.first(where: \.isDefault)?.id
                let choices = presets.map(\.id)
                presetID = currentProject.lastPresetID.flatMap { choices.contains($0) ? $0 : nil } ?? model.presetSets.first { $0.id == currentProject.presetSetID }?.defaultPresetID.flatMap { choices.contains($0) ? $0 : nil } ?? presets.first?.id
                folderID = currentProject.folders.first { $0.id == initialFolderID && $0.registered }?.id ?? currentProject.folders.first(where: \.registered)?.id
                checkout = startsInNewWorktree ? .newWorktree : .repository
                #if DEBUG
                configureProbe()
                #endif
            }
            .onDisappear {
                #if DEBUG
                QuickSessionProbe.sheetCommand = nil; QuickSessionProbe.sheetState = nil
                #endif
            }
            .onChange(of: operation.createdWorktree?.id) { _, _ in
                if let created = operation.createdWorktree { checkout = .existing(created.id); shared = false }
            }
            .task(id: "\(folderID?.uuidString ?? ""):\(checkout == .newWorktree):\(branch)") {
                destination = ""
                guard checkout == .newWorktree, let folderID, !branch.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(250)); guard !Task.isCancelled else { return }
                if let result = try? await model.call("previewWorktree", .object(["projectID": .string(project.id.uuidString), "folderID": .string(folderID.uuidString), "branch": .string(branch)])), !Task.isCancelled { destination = result["path"].string ?? "" }
            }
    }
    private var sessionFields: some View {
        Form {
            TextField("Title (optional)", text: $title)
            Picker("Group", selection: $groupID) {
                Text("Choose a group").tag(UUID?.none)
                ForEach(currentProject.groups.filter { !$0.archived }) { group in Text(group.name).tag(Optional(group.id)) }
            }
            Picker("Agent preset", selection: $presetID) {
                Text("Choose a preset").tag(UUID?.none)
                ForEach(presets) { preset in Text("\(preset.name) · \(preset.kind == .codex ? "Codex" : "Claude Code")").tag(Optional(preset.id)) }
            }
            if let preset { LabeledContent("Configuration", value: preset.configurationDirectory).font(.caption).textSelection(.enabled) }
        }
    }
    private var checkoutFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Checkout").font(.headline)
            Form {
                Picker("Repository", selection: $folderID) {
                    Text("Choose a folder").tag(UUID?.none)
                    ForEach(currentProject.folders.filter(\.registered)) { folder in Text(folder.name).tag(Optional(folder.id)) }
                }.onChange(of: folderID) { _, _ in checkout = startsInNewWorktree ? .newWorktree : .repository; shared = false }
                Picker("Work in", selection: $checkout) {
                    Text("Repository folder").tag(Checkout.repository)
                    ForEach(worktrees) { tree in Text("\(tree.branch.isEmpty ? "Detached HEAD" : tree.branch) · \(tree.availability.rawValue)").tag(Checkout.existing(tree.id)) }
                    Divider()
                    Text("New worktree…").tag(Checkout.newWorktree)
                }.onChange(of: checkout) { _, _ in shared = false }
                if checkout == .newWorktree {
                    TextField("New branch", text: $branch).autocorrectionDisabled()
                    TextField("Base ref", text: $baseRef).autocorrectionDisabled()
                }
            }
            if checkout == .newWorktree { Text("Creates a separate checkout for this repository, then starts your agent there.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private var additionalFolders: some View {
        if currentProject.folders.contains(where: { $0.registered && $0.id != folderID }) {
            DisclosureGroup("Additional repository access") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(currentProject.folders.filter { $0.registered && $0.id != folderID }) { folder in
                        Toggle(isOn: Binding(get: { additional.contains(folder.id) }, set: { if $0 { additional.insert(folder.id) } else { additional.remove(folder.id) } })) {
                            VStack(alignment: .leading) { Text(folder.name); Text(folder.canonicalPath).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Text("Additional repositories use these existing paths. A worktree for the primary repository does not isolate them.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
        }
    }
    private func launch(retry: Bool) {
        if retry {
            Task { finish(await operation.retry(model: model)) }
            return
        }
        guard let groupID, let presetID, let folderID else { return }
        let request = LaunchRequest(projectID: project.id, groupID: groupID, presetID: presetID, folderID: folderID, title: title.isEmpty ? "\(preset?.name ?? "Agent") · \(folder?.name ?? "Session")" : title, worktreeID: worktreeID, additionalFolderIDs: additional.filter { $0 != folderID }.sorted { $0.uuidString < $1.uuidString }, task: task.isEmpty ? nil : task, allowSharedCheckout: shared, coordinationEnabled: coordination)
        let creation = checkout == .newWorktree ? WorktreeCreationRequest(projectID: project.id, folderID: folderID, branch: branch, baseRef: baseRef) : nil
        Task {
            finish(await operation.launch(request, creating: creation, retry: false, model: model))
        }
    }
    private func finish(_ session: Session?) {
        if let session { completion(session.id); dismiss() }
    }
    #if DEBUG
    private func configureProbe() {
        guard QuickSessionProbe.enabled else { return }
        QuickSessionProbe.sheetCommand = { command in
            switch command["action"].string {
            case "configure":
                if let value = command["branch"].string { branch = value }
                if let value = command["task"].string { task = value }
                coordination = false
            case "launch": if canLaunch { launch(retry: false) }
            case "retry": if !operation.isBusy { launch(retry: true) }
            default: break
            }
        }
        QuickSessionProbe.sheetState = {
            .object(["branch": .string(branch), "destination": .string(destination), "busy": .bool(operation.isBusy), "canLaunch": .bool(canLaunch), "worktreeID": worktreeID.map { .string($0.uuidString) } ?? .null, "path": .string(primaryPath), "failure": operation.failure.map(JSONValue.string) ?? .null])
        }
    }
    #endif
}
