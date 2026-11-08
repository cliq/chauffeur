import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// New session, last step: agent or shell in the chosen location, which may be a worktree
/// the Mac creates first.
///
/// One `operationKey` lives for the whole screen. A retry after a failure reuses it while the
/// request payload is unchanged, so the Mac resolves it to the original worktree and session;
/// editing any field after a failure starts a new operation.
struct LaunchView: View {
    enum Kind: Hashable, CaseIterable {
        case agent
        case shell

        var label: String {
            switch self {
            case .agent: "Agent"
            case .shell: "Shell"
            }
        }
    }

    private struct Failure {
        var fingerprint: String
        var message: String
        var worktreeCreated: Bool
    }

    var model: MobileAppModel
    let location: LaunchLocation
    /// Title and task from an earlier step, applied once.
    var prefill = LaunchPrefill()

    @State private var kind: Kind = .agent
    @State private var presetID: UUID?
    @State private var title = ""
    @State private var initialTask = ""
    /// The last title a ticket was resolved for, so a resolved key is not looked up again.
    @State private var resolvedTitle: String?
    @State private var groupID: UUID?
    @State private var allowSharedCheckout = false
    @State private var coordination = false
    @State private var namingGroup = false
    @State private var newGroupName = ""
    @State private var groupError: String?
    @State private var showsMessaging = false
    @State private var appliedRepositoryChoices = false
    @State private var operationKey = UUID()
    @State private var isLaunching = false
    @State private var failure: Failure?

    private var inventory: InventorySnapshot? { model.inventory }

    private var project: ProjectSummary? {
        inventory?.project(location.projectID)
    }

    private var folder: FolderSummary? {
        inventory?.folder(location.folderID)
    }

    private var existingCheckout: CheckoutSummary? {
        guard case .existing(let path) = location.checkout else { return nil }
        return inventory?.checkout(path: path)
    }

    /// Another live session already runs in this checkout.
    private var isSharedCheckout: Bool {
        guard case .existing(let path) = location.checkout else { return false }
        return model.liveSessions.contains { $0.checkoutPath == path }
    }

    /// Older Macs ignore the flag, so the toggle only appears when the Mac would honor it.
    private var offersCoordination: Bool {
        kind == .agent && model.launchCoordinationIsSupported
    }

    private var canLaunch: Bool {
        guard model.isConnected, !isLaunching else { return false }
        if kind == .agent, presetID == nil { return false }
        return true
    }

    var body: some View {
        Form {
            Section {
                LocationSummary(model: model, location: location, showsLiveCount: false)
                    .accessibilityIdentifier("launch-location")
                if let note = existingCheckout?.note {
                    Label(note, systemImage: "note.text")
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("launch-checkout-note")
                }
            }

            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            if kind == .agent {
                Section("Agent preset") {
                    if let presets = project?.presets, !presets.isEmpty {
                        Picker("Preset", selection: $presetID) {
                            ForEach(presets) { preset in
                                HStack {
                                    Text(preset.name)
                                    KindBadge(kind: preset.kind)
                                }
                                .tag(Optional(preset.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } else {
                        Text("This project has no agent presets. Add one on the Mac or open a shell.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Initial task (optional)") {
                    TextField("What should the agent start with?", text: $initialTask, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("launch-task")
                }
            } else {
                Section {
                    Text("Open your Mac's login shell in this checkout.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Title (optional)") {
                TextField("Session title", text: $title)
                    .accessibilityIdentifier("launch-title")
            }

            messagingSection

            if isSharedCheckout {
                Section {
                    Toggle(isOn: $allowSharedCheckout) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch in a shared checkout")
                                .font(.subheadline.weight(.semibold))
                            Text("Another session is already running here. Both will see each other's changes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let failure {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.message)
                                .font(.subheadline)
                            Text(failure.worktreeCreated
                                 ? "Worktree created; retry launches in it."
                                 : "Retry keeps the original operation while nothing changed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("launch-error")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            launchBar
        }
        .alert("New group", isPresented: $namingGroup) {
            TextField("Group name", text: $newGroupName)
                .accessibilityIdentifier("launch-new-group-name")
            Button("Create") {
                Task { await createGroup() }
            }
            .disabled(trimmed(newGroupName).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions in this group message and delegate only to each other.")
        }
        .navigationTitle(kind == .agent ? "Launch agent" : "Open shell")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: applyDefaults)
        .task(id: title) {
            await resolveTitleTicket()
        }
    }

    /// The Launch button, kept above the keyboard and the form's end.
    private var launchBar: some View {
        VStack(spacing: 6) {
            Button {
                Task { await launch() }
            } label: {
                HStack {
                    if isLaunching {
                        ProgressView()
                    }
                    Text(buttonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canLaunch)
            .accessibilityIdentifier("launch-button")
            if !model.isConnected {
                Text("Reconnect to your Mac to launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Remembered per repository, so it stays folded behind a summary of the current choice.
    private var messagingSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsMessaging) {
                if offersCoordination {
                    Toggle(isOn: $coordination) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Chauffeur messaging and delegation")
                                .font(.subheadline.weight(.semibold))
                            Text(coordination
                                 ? "Experimental: CLI integration is under compatibility validation."
                                 : "Basic terminal mode: messaging, delegation, and semantic status signals are unavailable.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("launch-coordination")
                }
                Picker("Group", selection: $groupID) {
                    Text("Project default").tag(UUID?.none)
                    ForEach(project?.groups ?? []) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                if model.groupCreationIsSupported {
                    Button("New group…") {
                        newGroupName = ""
                        groupError = nil
                        namingGroup = true
                    }
                    .disabled(!model.isConnected)
                    .accessibilityIdentifier("launch-new-group")
                }
                if let groupError {
                    Text(groupError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } label: {
                LabeledContent(offersCoordination ? "Messaging" : "Group", value: messagingSummary)
            }
            .accessibilityIdentifier("launch-messaging")
        } footer: {
            Text(offersCoordination
                 ? "Sessions message and delegate only within their group. Each repository remembers these choices for its next agent."
                 : "Uses existing Mac configuration.")
        }
    }

    private var messagingSummary: String {
        let group = groupID.flatMap { id in project?.groups.first { $0.id == id }?.name } ?? "Project default"
        guard offersCoordination else { return group }
        return "\(coordination ? "On" : "Off") · \(group)"
    }

    private func createGroup() async {
        let name = trimmed(newGroupName)
        guard !name.isEmpty else { return }
        do {
            groupID = try await model.createGroup(projectID: location.projectID, name: name).id
            groupError = nil
        } catch let error as RemoteClientError {
            groupError = error.userMessage
        } catch {
            groupError = error.localizedDescription
        }
    }

    private var buttonTitle: String {
        if isLaunching { return "Launching…" }
        if failure != nil { return "Retry" }
        return kind == .agent ? "Launch agent" : "Open shell"
    }

    private func applyDefaults() {
        if !appliedRepositoryChoices {
            title = prefill.title ?? ""
            initialTask = prefill.task ?? ""
            resolvedTitle = prefill.title
        }
        if presetID == nil {
            presetID = project?.presets.first?.id
        }
        if project?.presets.isEmpty == true {
            kind = .shell
        }
        // The repository remembers the last agent's group and messaging choice. Applied once, so returning
        // from a pushed picker keeps what the user changed.
        guard !appliedRepositoryChoices else { return }
        appliedRepositoryChoices = true
        if let remembered = folder?.lastGroupID, project?.groups.contains(where: { $0.id == remembered }) == true {
            groupID = remembered
        }
        coordination = folder?.lastCoordinationEnabled ?? false
    }

    /// A pasted ticket link becomes the ticket's key, and an empty task becomes the link's task.
    /// Older Macs leave the title as typed.
    private func resolveTitleTicket() async {
        let text = title
        guard text.contains("://"), resolvedTitle != text else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              let ticket = try? await model.resolveTicket(projectID: location.projectID, folderID: location.folderID, text: text),
              !Task.isCancelled, title == text, ticket.url != nil else { return }
        if trimmed(initialTask).isEmpty, let task = ticket.task {
            initialTask = task
        }
        resolvedTitle = ticket.title
        title = ticket.title
    }

    private func buildRequest() -> LaunchOperationRequest? {
        var agentPresetID: UUID?
        if kind == .agent {
            guard let presetID else { return nil }
            agentPresetID = presetID
        }
        let worktreeID: UUID?
        let newWorktree: WorktreeCreationSpec?
        switch location.checkout {
        case .existing:
            worktreeID = existingCheckout?.worktreeID
            newWorktree = nil
        case .newWorktree(let draft):
            worktreeID = nil
            newWorktree = draft.spec
        }
        let spec = LaunchSpec(
            projectID: location.projectID,
            folderID: location.folderID,
            groupID: groupID,
            worktreeID: worktreeID,
            agentPresetID: agentPresetID,
            title: optional(title),
            task: optional(initialTask),
            allowSharedCheckout: isSharedCheckout && allowSharedCheckout,
            coordinationEnabled: offersCoordination && coordination
        )
        let fingerprint = LaunchOperationRequest.computeFingerprint(newWorktree: newWorktree, launch: spec)
        // A changed payload after a failure is a new operation, never a retry of the old one.
        if let failure, failure.fingerprint != fingerprint {
            operationKey = UUID()
        }
        return LaunchOperationRequest(operationKey: operationKey, fingerprint: fingerprint, newWorktree: newWorktree, launch: spec)
    }

    private func launch() async {
        guard let request = buildRequest() else { return }
        isLaunching = true
        defer { isLaunching = false }
        switch await model.launch(request) {
        case .launched:
            failure = nil
        case .failed(let message, let worktreeCreated):
            failure = Failure(fingerprint: request.fingerprint, message: message, worktreeCreated: worktreeCreated)
        }
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optional(_ text: String) -> String? {
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}

#Preview("Existing checkout") {
    let model = MobileAppModel.preview()
    let session = model.inventory!.sessions[0]
    return NavigationStack {
        LaunchView(model: model, location: model.location(of: session))
    }
}

#Preview("New worktree") {
    let model = MobileAppModel.preview()
    let project = model.inventory!.projects[0]
    return NavigationStack {
        LaunchView(
            model: model,
            location: LaunchLocation(projectID: project.id, folderID: project.folders[0].id,
                                     checkout: .newWorktree(NewWorktreeDraft(branch: "feature/search", baseRef: "main", reuseExistingBranch: false,
                                                                             destination: "/Users/leo/Chauffeur/.worktrees/feature-search"))),
            prefill: LaunchPrefill(title: "Search projects", task: nil)
        )
    }
}
