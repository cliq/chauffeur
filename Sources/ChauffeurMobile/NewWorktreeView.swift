import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// New session, worktree step: the branch for a managed worktree, named from a ticket or
/// title that also titles the session on the Launch screen.
struct NewWorktreeView: View {
    var model: MobileAppModel
    let projectID: UUID
    let folderID: UUID
    /// The starting point to preselect, such as the branch of the session this was opened from.
    var initialBaseRef: String?

    @State private var title = ""
    /// A pasted ticket's task, handed to the Launch screen.
    @State private var task: String?
    @State private var branch = ""
    @State private var suggestedBranch = ""
    /// The branch the Mac rendered for a ticket title, kept so retitling to the key does not fall back to a slug.
    @State private var ticketBranch: (title: String, branch: String)?
    @State private var baseRef = ""
    @State private var existingBranch = ""
    @State private var reuseExistingBranch = false
    @State private var choosingBaseRef = false
    @State private var destination: String?
    @State private var destinationError: String?
    @State private var appliedDefaults = false

    private var folder: FolderSummary? { model.inventory?.folder(folderID) }
    private var selectedBranch: String { trimmed(reuseExistingBranch ? existingBranch : branch) }

    private var draft: NewWorktreeDraft? {
        guard !selectedBranch.isEmpty, reuseExistingBranch || !trimmed(baseRef).isEmpty else { return nil }
        return NewWorktreeDraft(branch: selectedBranch, baseRef: trimmed(baseRef), reuseExistingBranch: reuseExistingBranch, destination: destination)
    }

    var body: some View {
        Form {
            Section {
                TextField("Ticket link or title", text: $title)
                    .accessibilityIdentifier("worktree-title")
            } header: {
                Text("Ticket or title (optional)")
            } footer: {
                Text("Names the branch and the session. A pasted ticket link also fills in the initial task.")
            }

            Section {
                Picker("Branch", selection: $reuseExistingBranch) {
                    Text("New branch").tag(false)
                    Text("Existing branch").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("launch-branch-mode")
            }

            if reuseExistingBranch {
                Section {
                    WorktreeBranchPicker(model: model, projectID: projectID, folderID: folderID, selection: $existingBranch)
                } footer: {
                    Text("A local branch not checked out anywhere yet.")
                }
            } else {
                Section {
                    LabeledContent("Branch") {
                        TextField("branch-name", text: $branch)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .accessibilityIdentifier("launch-branch")
                    }
                    LabeledContent("Starting point") {
                        HStack {
                            TextField("HEAD", text: $baseRef)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                                .accessibilityIdentifier("launch-base-ref")
                            Button("Choose a branch", systemImage: "list.bullet") {
                                choosingBaseRef = true
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("launch-base-ref-choose")
                        }
                    }
                } footer: {
                    Text("Any branch, tag, or commit the new branch starts from.")
                }
            }

            Section {
                LabeledContent("Destination") {
                    if let destinationError {
                        Text(destinationError)
                            .foregroundStyle(.orange)
                    } else if let destination {
                        Text(destination)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.trailing)
                    } else if selectedBranch.isEmpty {
                        Text(reuseExistingBranch ? "Choose a branch" : "Enter a branch")
                    } else {
                        ProgressView()
                    }
                }
                .foregroundStyle(.secondary)
            } footer: {
                Text("The Mac creates a managed worktree here when the session launches.")
            }
        }
        .sheet(isPresented: $choosingBaseRef) {
            WorktreeBranchPickerSheet(model: model, projectID: projectID, folderID: folderID, purpose: .startingPoint, selection: $baseRef)
        }
        .navigationTitle("New worktree")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") {
                    guard let draft else { return }
                    let location = LaunchLocation(projectID: projectID, folderID: folderID, checkout: .newWorktree(draft))
                    model.path.append(.launch(location, prefill: LaunchPrefill(title: optional(title), task: task)))
                }
                .disabled(draft == nil)
                .accessibilityIdentifier("worktree-continue")
            }
        }
        .onAppear(perform: applyDefaults)
        .onChange(of: title) { _, newTitle in
            if let ticketBranch, ticketBranch.title == newTitle {
                suggestBranch(ticketBranch.branch)
            } else {
                // Retyped away from the ticket: its task no longer applies.
                task = nil
                suggestBranch(WorktreeCreationSpec.branchSlug(from: newTitle))
            }
        }
        .task(id: title) {
            await resolveTitleTicket()
        }
        .task(id: branch) {
            await resolveBranchTicket()
        }
        .task(id: selectedBranch) {
            await previewDestination()
        }
    }

    /// Starts from the main checkout's branch, the same commit as `HEAD` but named. Applied once,
    /// so returning from Launch keeps what the user changed.
    private func applyDefaults() {
        guard !appliedDefaults else { return }
        appliedDefaults = true
        let main = folder?.checkouts.first { $0.kind == .main }?.branch
        baseRef = initialBaseRef ?? main.flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
    }

    /// Fills the branch from the title until the branch is edited by hand.
    private func suggestBranch(_ suggestion: String) {
        if branch.isEmpty || branch == suggestedBranch {
            branch = suggestion
        }
        suggestedBranch = suggestion
    }

    /// A pasted ticket link becomes the ticket's key and its task; a bare key only changes the
    /// suggested branch. Older Macs leave the title as typed.
    private func resolveTitleTicket() async {
        let text = title
        guard !trimmed(text).isEmpty, ticketBranch?.title != text else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              let ticket = try? await model.resolveTicket(projectID: projectID, folderID: folderID, text: text),
              !Task.isCancelled, title == text else { return }
        if ticket.url != nil {
            if let ticketTask = ticket.task { task = ticketTask }
            ticketBranch = (ticket.title, ticket.branch)
            title = ticket.title
        } else {
            ticketBranch = (text, ticket.branch)
            suggestBranch(ticket.branch)
        }
    }

    /// Only a link is rewritten here: a key typed by hand would match before it is finished.
    private func resolveBranchTicket() async {
        let text = branch
        guard !reuseExistingBranch, text.contains("://") else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              let ticket = try? await model.resolveTicket(projectID: projectID, folderID: folderID, text: text),
              !Task.isCancelled, branch == text, ticket.url != nil else { return }
        branch = ticket.branch
    }

    /// Debounced 300 ms so typing a branch does not send a request per keystroke.
    private func previewDestination() async {
        let branch = selectedBranch
        destination = nil
        destinationError = nil
        guard !branch.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let path = try await model.previewWorktree(projectID: projectID, folderID: folderID, branch: branch)
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

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optional(_ text: String) -> String? {
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}

#Preview {
    let model = MobileAppModel.preview()
    let project = model.inventory!.projects[0]
    return NavigationStack {
        NewWorktreeView(model: model, projectID: project.id, folderID: project.folders[0].id)
    }
}
