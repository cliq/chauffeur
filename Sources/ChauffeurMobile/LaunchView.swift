import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// 05 / Launch: agent or shell in the chosen location; new-worktree fields inline.
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

    @State private var kind: Kind = .agent
    @State private var presetID: UUID?
    @State private var title = ""
    @State private var initialTask = ""
    @State private var branch = ""
    @State private var suggestedBranch = ""
    @State private var baseRef = "HEAD"
    @State private var groupID: UUID?
    @State private var allowSharedCheckout = false
    @State private var destination: String?
    @State private var destinationError: String?
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

    private var isNewWorktree: Bool {
        location.checkout == .newWorktree
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

    private var canLaunch: Bool {
        guard model.isConnected, !isLaunching else { return false }
        if kind == .agent, presetID == nil { return false }
        if isNewWorktree, trimmed(branch).isEmpty || trimmed(baseRef).isEmpty { return false }
        return true
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Location", value: model.describe(location))
                Button("Change location") {
                    model.path.removeLast()
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
                }
            } else {
                Section {
                    Text("Open your Mac's login shell in this checkout.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Title (optional)") {
                TextField("Session title", text: $title)
            }

            if isNewWorktree {
                Section {
                    TextField("Branch", text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("launch-branch")
                    TextField("Base ref", text: $baseRef)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("launch-base-ref")
                    LabeledContent("Destination") {
                        if let destinationError {
                            Text(destinationError)
                                .foregroundStyle(.orange)
                        } else if let destination {
                            Text(destination)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                        } else if trimmed(branch).isEmpty {
                            Text("Enter a branch")
                        } else {
                            ProgressView()
                        }
                    }
                    .foregroundStyle(.secondary)
                } header: {
                    Text("New worktree")
                } footer: {
                    Text("The Mac creates a managed worktree at the destination shown, then launches in it.")
                }
            }

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

            Section {
                Picker("Group", selection: $groupID) {
                    Text("Project default").tag(UUID?.none)
                    ForEach(project?.groups ?? []) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
            } footer: {
                Text("Uses existing Mac configuration.")
            }

            if let failure {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(failure.message)
                                .font(.subheadline)
                            if failure.worktreeCreated {
                                Text("Worktree created; retry launches in it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("launch-error")
                }
            }

            Section {
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
                .disabled(!canLaunch)
                .accessibilityIdentifier("launch-button")
            } footer: {
                Text(model.isConnected
                     ? "Launch opens a terminal tab. Errors stay here; retry keeps the original operation while nothing changed."
                     : "Reconnect to your Mac to launch.")
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Launch session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: applyDefaults)
        .onChange(of: title) { _, newTitle in
            let slug = Self.branchSlug(from: newTitle)
            if branch.isEmpty || branch == suggestedBranch {
                branch = slug
            }
            suggestedBranch = slug
        }
        .task(id: trimmed(branch)) {
            await previewDestination()
        }
    }

    private var buttonTitle: String {
        if isLaunching { return "Launching…" }
        if failure != nil { return "Retry" }
        return kind == .agent ? "Launch agent" : "Open shell"
    }

    private func applyDefaults() {
        if presetID == nil {
            presetID = project?.presets.first?.id
        }
        if project?.presets.isEmpty == true {
            kind = .shell
        }
    }

    /// Debounced 300 ms so typing a branch does not send a request per keystroke.
    private func previewDestination() async {
        let branch = trimmed(branch)
        destination = nil
        destinationError = nil
        guard isNewWorktree, !branch.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let path = try await model.previewWorktree(projectID: location.projectID, folderID: location.folderID, branch: branch)
            guard !Task.isCancelled else { return }
            destination = path
        } catch let error as RemoteClientError {
            guard !Task.isCancelled else { return }
            destinationError = error.userMessage
        } catch {
            guard !Task.isCancelled else { return }
            destinationError = String(describing: error)
        }
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
        case .newWorktree:
            worktreeID = nil
            newWorktree = WorktreeCreationSpec(branch: trimmed(branch), baseRef: trimmed(baseRef))
        }
        let spec = LaunchSpec(
            projectID: location.projectID,
            folderID: location.folderID,
            groupID: groupID,
            worktreeID: worktreeID,
            agentPresetID: agentPresetID,
            title: optional(title),
            task: optional(initialTask),
            allowSharedCheckout: isSharedCheckout && allowSharedCheckout
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

    /// Lowercase slug: letters and digits kept, everything else collapsed to a single hyphen.
    static func branchSlug(from title: String) -> String {
        var slug = ""
        var previousWasHyphen = true
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                slug.append("-")
                previousWasHyphen = true
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug
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
            location: LaunchLocation(projectID: project.id, folderID: project.folders[0].id, checkout: .newWorktree)
        )
    }
}
