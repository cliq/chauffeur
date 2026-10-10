import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// Starts an agent or shell on the remote server: where (project, folder, checkout or a new
/// worktree), then what. Mirrors the iPhone's Location and Launch screens in one sheet.
///
/// One `operationKey` lives for the sheet. A retry after a failure reuses it while the request is
/// unchanged, so the server resolves it to the original worktree and session; editing any field
/// after a failure starts a new operation.
struct RemoteLaunchSheet: View {
    private enum Kind: Hashable { case agent, shell }
    /// `nil` path means a new worktree.
    private struct CheckoutChoice: Hashable { var path: String? }
    private struct Failure { var fingerprint: String; var message: String; var worktreeCreated: Bool }

    var model: RemoteHostModel
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: UUID?
    @State private var folderID: UUID?
    @State private var checkout: CheckoutChoice?
    @State private var kind: Kind = .agent
    @State private var presetID: UUID?
    @State private var groupID: UUID?
    @State private var coordination = false
    @State private var title = ""
    @State private var initialTask = ""
    @State private var reuseExistingBranch = false
    @State private var branch = ""
    @State private var suggestedBranch = ""
    @State private var existingBranch = ""
    @State private var baseRef = "HEAD"
    @State private var branches: [WorktreeBranchOption]?
    @State private var destination: String?
    @State private var destinationError: String?
    @State private var allowSharedCheckout = false
    @State private var newGroupName = ""
    @State private var namingGroup = false
    @State private var groupError: String?
    @State private var operationKey = UUID()
    @State private var isLaunching = false
    @State private var failure: Failure?

    private var inventory: InventorySnapshot? { model.inventory }
    private var projects: [ProjectSummary] { inventory?.projects.filter { !$0.archived } ?? [] }
    private var project: ProjectSummary? { projectID.flatMap { inventory?.project($0) } }
    private var folder: FolderSummary? { folderID.flatMap { inventory?.folder($0) } }
    private var isNewWorktree: Bool { checkout != nil && checkout?.path == nil }
    private var existingCheckout: CheckoutSummary? { checkout?.path.flatMap { inventory?.checkout(path: $0) } }
    private var selectedBranch: String { reuseExistingBranch ? existingBranch : branch }
    private var isSharedCheckout: Bool {
        guard let path = checkout?.path else { return false }
        return model.liveSessions.contains { $0.checkoutPath == path }
    }
    private var offersCoordination: Bool { kind == .agent && model.launchCoordinationIsSupported }

    private var canLaunch: Bool {
        guard model.isConnected, !isLaunching, projectID != nil, folderID != nil, checkout != nil else { return false }
        if kind == .agent, presetID == nil { return false }
        if isNewWorktree, trimmed(selectedBranch).isEmpty || (!reuseExistingBranch && trimmed(baseRef).isEmpty) { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                locationSection
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Agent").tag(Kind.agent)
                        Text("Shell").tag(Kind.shell)
                    }
                    .pickerStyle(.segmented)
                    if kind == .agent {
                        if let presets = project?.presets, !presets.isEmpty {
                            Picker("Agent", selection: $presetID) {
                                ForEach(presets) { preset in Text("\(preset.name) · \(preset.kind.label)").tag(Optional(preset.id)) }
                            }
                        } else {
                            Text("This project has no agents on the server. Open a shell instead.").foregroundStyle(.secondary)
                        }
                    }
                    TextField("Title", text: $title, prompt: Text("Optional"))
                    if kind == .agent {
                        TextField("Initial task", text: $initialTask, prompt: Text("Optional"), axis: .vertical).lineLimit(2...5)
                    }
                }
                groupSection
                if isNewWorktree { worktreeSection }
                if isSharedCheckout {
                    Section {
                        Toggle("Launch in a shared checkout", isOn: $allowSharedCheckout)
                        Text("Another session is already running here. Both will see each other's changes.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let failure {
                    Section {
                        Label(failure.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        if failure.worktreeCreated { Text("Worktree created; retry launches in it.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                if !model.isConnected { Text("Reconnect to the server to launch.").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await launch() }
                } label: {
                    HStack {
                        if isLaunching { ProgressView().controlSize(.small) }
                        Text(isLaunching ? "Launching…" : failure != nil ? "Retry" : kind == .agent ? "Launch Agent" : "Open Shell")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canLaunch)
            }
            .padding()
        }
        .frame(width: 560, height: 640)
        .alert("New Group", isPresented: $namingGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Create") { Task { await createGroup() } }.disabled(trimmed(newGroupName).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions in this group message and delegate only to each other.")
        }
        .onAppear(perform: applyDefaults)
        .onChange(of: projectID) { _, _ in
            // Defaults set the project and its folder together; keep a folder that belongs to it.
            if project?.folders.contains(where: { $0.id == folderID }) != true { folderID = project?.folders.first?.id }
            if project?.presets.contains(where: { $0.id == presetID }) != true { presetID = project?.presets.first?.id }
            applyRepositoryChoices()
            selectDefaultCheckout()
        }
        .onChange(of: folderID) { _, _ in
            applyRepositoryChoices()
            selectDefaultCheckout()
            branches = nil
        }
        .onChange(of: title) { _, newTitle in suggestBranch(WorktreeCreationSpec.branchSlug(from: newTitle)) }
        // Each lookup restarts when any of its inputs changes, and drops a result that arrives late.
        .task(id: "\(folderID?.uuidString ?? "")|\(title)") { await resolveTitleTicket() }
        .task(id: "\(folderID?.uuidString ?? "")|\(isNewWorktree)|\(trimmed(selectedBranch))") { await previewDestination() }
        .task(id: "\(folderID?.uuidString ?? "")|\(reuseExistingBranch)") { await loadBranches() }
    }

    // MARK: Sections

    private var locationSection: some View {
        Section("Location") {
            Picker("Project", selection: $projectID) {
                ForEach(projects) { project in Text(project.name).tag(Optional(project.id)) }
            }
            if let project {
                Picker("Folder", selection: $folderID) {
                    ForEach(project.folders) { folder in
                        Text(folder.availability == .available ? folder.name : "\(folder.name) (unavailable)").tag(Optional(folder.id))
                    }
                }
            }
            if let folder {
                Picker("Checkout", selection: $checkout) {
                    ForEach(folder.checkouts) { existing in
                        Text("\(existing.kind == .main ? "Main" : "Worktree") · \(existing.branch)")
                            .tag(Optional(CheckoutChoice(path: existing.path)))
                            .disabled(existing.availability != .available)
                    }
                    if folder.isRepository {
                        Divider()
                        Text("New worktree…").tag(Optional(CheckoutChoice(path: nil)))
                    }
                }
                if let path = checkout?.path {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var groupSection: some View {
        Section {
            if offersCoordination {
                Toggle("Enable Chauffeur messaging and delegation", isOn: $coordination)
            }
            HStack {
                Picker("Group", selection: $groupID) {
                    Text("Project default").tag(UUID?.none)
                    ForEach(project?.groups ?? []) { group in Text(group.name).tag(Optional(group.id)) }
                }
                if model.groupCreationIsSupported {
                    Button("New Group…") { newGroupName = ""; groupError = nil; namingGroup = true }.disabled(!model.isConnected)
                }
            }
            if let groupError { Text(groupError).font(.caption).foregroundStyle(.orange) }
        }
    }

    private var worktreeSection: some View {
        Section("New worktree") {
            Picker("Branch", selection: $reuseExistingBranch) {
                Text("New branch").tag(false)
                Text("Existing branch").tag(true)
            }
            .pickerStyle(.segmented)
            if reuseExistingBranch {
                if let branches {
                    Picker("Existing branch", selection: $existingBranch) {
                        Text("Choose a branch…").tag("")
                        ForEach(branches) { option in
                            Text(option.isCheckedOut ? "\(option.name) (checked out)" : option.name).tag(option.name).disabled(option.isCheckedOut)
                        }
                    }
                } else {
                    ProgressView("Loading branches…").controlSize(.small)
                }
            } else {
                TextField("New branch", text: $branch)
                TextField("Base ref", text: $baseRef)
            }
            LabeledContent("Destination") {
                if let destinationError {
                    Text(destinationError).foregroundStyle(.orange)
                } else if let destination {
                    Text(destination).font(.caption.monospaced()).textSelection(.enabled)
                } else if trimmed(selectedBranch).isEmpty {
                    Text(reuseExistingBranch ? "Choose a branch" : "Enter a branch").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: Defaults

    private func applyDefaults() {
        guard projectID == nil else { return }
        // Start where the selected session runs, so a second agent next to it is two clicks away.
        if let selected = model.selectedSessionID.flatMap(model.session) {
            projectID = selected.projectID
            folderID = selected.folderID
            checkout = CheckoutChoice(path: selected.checkoutPath)
        } else {
            projectID = projects.first?.id
            folderID = project?.folders.first?.id
            selectDefaultCheckout()
        }
        presetID = project?.presets.first?.id
        if project?.presets.isEmpty == true { kind = .shell }
        applyRepositoryChoices()
    }

    /// The repository remembers the last agent's group and messaging choice.
    private func applyRepositoryChoices() {
        if let remembered = folder?.lastGroupID, project?.groups.contains(where: { $0.id == remembered }) == true {
            groupID = remembered
        } else {
            groupID = nil
        }
        coordination = folder?.lastCoordinationEnabled ?? false
    }

    private func selectDefaultCheckout() {
        if let path = checkout?.path, folder?.checkouts.contains(where: { $0.path == path }) == true { return }
        let available = folder?.checkouts.filter { $0.availability == .available } ?? []
        let main = available.first(where: { $0.kind == .main }) ?? available.first
        checkout = main.map { CheckoutChoice(path: $0.path) } ?? (folder?.isRepository == true ? CheckoutChoice(path: nil) : nil)
    }

    private func suggestBranch(_ suggestion: String) {
        if branch.isEmpty || branch == suggestedBranch { branch = suggestion }
        suggestedBranch = suggestion
    }

    // MARK: Server lookups

    private func resolveTitleTicket() async {
        let text = title
        guard let projectID, let folderID, !trimmed(text).isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              let ticket = try? await model.resolveTicket(projectID: projectID, folderID: folderID, text: text),
              !Task.isCancelled, title == text, self.folderID == folderID else { return }
        if ticket.url != nil {
            if trimmed(initialTask).isEmpty, let task = ticket.task { initialTask = task }
            title = ticket.title
        }
        suggestBranch(ticket.branch)
    }

    private func previewDestination() async {
        let branch = trimmed(selectedBranch)
        destination = nil
        destinationError = nil
        guard isNewWorktree, !branch.isEmpty, let projectID, let folderID else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let path = try await model.previewWorktree(projectID: projectID, folderID: folderID, branch: branch)
            guard !Task.isCancelled, self.folderID == folderID else { return }
            destination = path
        } catch {
            guard !Task.isCancelled else { return }
            destinationError = (error as? RemoteClientError)?.userMessage ?? String(describing: error)
        }
    }

    private func loadBranches() async {
        guard reuseExistingBranch, branches == nil, let projectID, let folderID else { return }
        let loaded = (try? await model.worktreeBranches(projectID: projectID, folderID: folderID)) ?? []
        guard !Task.isCancelled, self.folderID == folderID else { return }
        branches = loaded
    }

    private func createGroup() async {
        let name = trimmed(newGroupName)
        guard let projectID, !name.isEmpty else { return }
        do {
            groupID = try await model.createGroup(projectID: projectID, name: name).id
            groupError = nil
        } catch {
            groupError = (error as? RemoteClientError)?.userMessage ?? error.localizedDescription
        }
    }

    // MARK: Launch

    private func buildRequest() -> LaunchOperationRequest? {
        guard let projectID, let folderID else { return nil }
        var agentPresetID: UUID?
        if kind == .agent {
            guard let presetID else { return nil }
            agentPresetID = presetID
        }
        let newWorktree = isNewWorktree
            ? WorktreeCreationSpec(branch: trimmed(selectedBranch), baseRef: reuseExistingBranch ? "HEAD" : trimmed(baseRef), reuseExistingBranch: reuseExistingBranch)
            : nil
        let spec = LaunchSpec(
            projectID: projectID,
            folderID: folderID,
            groupID: groupID,
            worktreeID: isNewWorktree ? nil : existingCheckout?.worktreeID,
            agentPresetID: agentPresetID,
            title: optional(title),
            task: kind == .agent ? optional(initialTask) : nil,
            allowSharedCheckout: isSharedCheckout && allowSharedCheckout,
            coordinationEnabled: offersCoordination && coordination
        )
        let fingerprint = LaunchOperationRequest.computeFingerprint(newWorktree: newWorktree, launch: spec)
        // A changed payload after a failure is a new operation, never a retry of the old one.
        if let failure, failure.fingerprint != fingerprint { operationKey = UUID() }
        return LaunchOperationRequest(operationKey: operationKey, fingerprint: fingerprint, newWorktree: newWorktree, launch: spec)
    }

    private func launch() async {
        guard let request = buildRequest() else { return }
        isLaunching = true
        defer { isLaunching = false }
        let result = await model.launch(request)
        if let message = result.failure {
            failure = Failure(fingerprint: request.fingerprint, message: message, worktreeCreated: result.worktreeCreated)
        } else {
            dismiss()
        }
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func optional(_ text: String) -> String? { let value = trimmed(text); return value.isEmpty ? nil : value }
}
