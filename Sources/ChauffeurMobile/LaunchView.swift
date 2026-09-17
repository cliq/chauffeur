import SwiftUI

/// 05 / Launch: agent or shell in the chosen location; new-worktree fields inline.
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

    private var inventory: InventorySnapshot? { model.inventory }

    private var isNewWorktree: Bool {
        location.checkout == .newWorktree
    }

    /// Another session already runs in this checkout.
    private var isSharedCheckout: Bool {
        guard case .existing(let checkoutID) = location.checkout, let inventory else { return false }
        return !inventory.sessions(inCheckout: checkoutID).isEmpty
    }

    private var canLaunch: Bool {
        if kind == .agent, presetID == nil { return false }
        if isNewWorktree, branch.isEmpty || baseRef.isEmpty { return false }
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
                    Picker("Preset", selection: $presetID) {
                        ForEach(inventory?.presets ?? []) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
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
                    TextField("Base ref", text: $baseRef)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    LabeledContent("Destination", value: "Preview pending…")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("New worktree")
                } footer: {
                    Text("Destination on Mac: managed worktree folder (preview before launch).")
                }
            }

            if isSharedCheckout {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shared checkout")
                                .font(.subheadline.weight(.semibold))
                            Text("Another session is already running in this checkout. Both will see each other's changes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Picker("Group", selection: $groupID) {
                    ForEach(inventory?.groups ?? []) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
            } footer: {
                Text("Uses existing Mac configuration.")
            }

            Section {
                Button {
                    launch()
                } label: {
                    Text(kind == .agent ? "Launch agent" : "Open shell")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canLaunch)
            } footer: {
                Text("Launch opens a terminal tab. Validation and launch errors stay here; retry keeps the original operation.")
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
    }

    private func applyDefaults() {
        if presetID == nil {
            presetID = inventory?.presets.first?.id
        }
        if groupID == nil {
            groupID = inventory?.defaultGroup?.id
        }
    }

    private func launch() {
        let requestKind: LaunchRequest.Kind
        switch kind {
        case .agent:
            guard let presetID else { return }
            requestKind = .agent(presetID: presetID)
        case .shell:
            requestKind = .shell
        }
        let request = LaunchRequest(
            kind: requestKind,
            title: title.trimmingCharacters(in: .whitespaces),
            initialTask: initialTask,
            branch: branch,
            baseRef: baseRef,
            groupID: groupID
        )
        model.launch(request, at: location)
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
