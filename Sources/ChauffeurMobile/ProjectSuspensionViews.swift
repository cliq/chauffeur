import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// Confirms suspending a project: which agents stop and resume later, which are interrupted
/// mid-turn, which terminals close, and what has to be closed on the Mac first.
struct SuspendProjectSheet: View {
    var model: MobileAppModel
    let project: ProjectSummary
    @Environment(\.dismiss) private var dismiss
    @State private var plan: RemoteSuspendPlan?
    @State private var failure: String?
    @State private var suspending = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Stops the project's Claude Code and Codex sessions once each has a saved conversation, and closes its terminals. Restoring the project resumes every agent where it left off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let plan {
                    planSections(plan)
                } else if failure == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking each agent's conversation…").foregroundStyle(.secondary)
                    }
                }
                if let plan, plan.canSuspend, case let fallbacks = plan.agents.filter({ !$0.conversationRecorded }), !fallbacks.isEmpty {
                    Section {
                        Label(fallbacks.count == 1 ? "One agent's conversation was found by searching transcripts and may not be the one it was running."
                              : "\(fallbacks.count) agents' conversations were found by searching transcripts and may not be the ones they were running.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("suspendProject.fallbackWarning")
                    }
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("suspendProject.error")
                    }
                }
            }
            .navigationTitle("Suspend \(project.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(suspending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if suspending {
                        ProgressView().accessibilityLabel("Suspending")
                    } else {
                        Button(suspendTitle) { Task { await suspend() } }
                            .disabled(plan?.canSuspend != true || !model.isConnected)
                            .accessibilityIdentifier("suspendProject.confirm")
                    }
                }
            }
            .interactiveDismissDisabled(suspending)
            .task { await load() }
        }
    }

    @ViewBuilder
    private func planSections(_ plan: RemoteSuspendPlan) -> some View {
        if !plan.blockers.isEmpty {
            Section {
                ForEach(plan.blockers) { blocker in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(blocker.title).font(.body.weight(.medium))
                        Text(blocker.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Close on your Mac first")
            } footer: {
                Text("Nothing is suspended while any of these is running.")
            }
        }
        if !plan.agents.isEmpty {
            Section("Agents to suspend") {
                ForEach(plan.agents) { agent in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(agent.title).font(.body.weight(.medium)).lineLimit(2)
                            Spacer(minLength: 8)
                            KindBadge(kind: agent.kind)
                        }
                        Text(agent.conversationRecorded ? "Resumes its conversation" : "Resumes a conversation found in the checkout's transcripts")
                            .font(.caption).foregroundStyle(.secondary)
                        if agent.activity != .idle {
                            Label(agent.activity == .working ? "Working · will be interrupted" : "May be working · will be interrupted",
                                  systemImage: "exclamationmark.circle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        if !plan.shells.isEmpty {
            Section("Terminals to close") {
                ForEach(plan.shells) { shell in
                    Label(shell.title, systemImage: "terminal")
                }
            }
        }
        if plan.agents.isEmpty && plan.blockers.isEmpty {
            Text("No Claude Code or Codex sessions are running in this project.").foregroundStyle(.secondary)
        }
    }

    private var suspendTitle: String {
        plan?.busyAgents.isEmpty == false ? "Interrupt and Suspend" : "Suspend"
    }

    private func load() async {
        failure = nil
        do {
            plan = try await model.suspendPlan(projectID: project.id)
        } catch {
            failure = Self.message(error)
        }
    }

    private func suspend() async {
        guard !suspending, let plan else { return }
        suspending = true; failure = nil
        defer { suspending = false }
        do {
            // Consent covers only the agents this sheet showed as working.
            try await model.suspendProject(plan)
            dismiss()
        } catch RemoteClientError.remote(let error) where error.code == "busy_sessions" {
            self.plan = nil
            await load()
            failure = "An agent started working. Check the list and confirm again."
        } catch RemoteClientError.timeout {
            if model.isSuspended(projectID: project.id) { dismiss(); return }
            failure = "The Mac is still suspending the project. Its sessions show as suspended once it finishes."
        } catch {
            failure = Self.message(error)
        }
    }

    static func message(_ error: Error) -> String {
        (error as? RemoteClientError)?.userMessage ?? error.localizedDescription
    }
}

/// A suspended project's sessions, each of which can be left out, and the Restore button.
struct RestoreProjectView: View {
    var model: MobileAppModel
    let projectID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var excluded = Set<UUID>()
    @State private var restoring = false
    @State private var failure: String?

    private var project: ProjectSummary? { model.inventory?.project(projectID) }
    private var sessions: [SessionSummary] { model.suspendedSessions(projectID: projectID) }
    private var selected: [SessionSummary] { sessions.filter { !excluded.contains($0.id) } }

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView("Not suspended", systemImage: "play.circle",
                                       description: Text("This project's sessions are no longer suspended."))
            } else {
                Section {
                    ForEach(sessions) { session in
                        Toggle(isOn: included(session.id)) { row(session) }
                            .disabled(restoring)
                            .accessibilityIdentifier("restoreProject.session")
                    }
                } header: {
                    if let since = sessions.compactMap(\.suspendedAt).min() {
                        Text("Suspended \(since.formatted(.relative(presentation: .named)))")
                    }
                } footer: {
                    Text("Restoring resumes each agent's conversation in its checkout. Sessions left off become ended sessions you can resume later on your Mac.")
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("restoreProject.error")
                    }
                }
                Section {
                    Button { Task { await restore() } } label: {
                        HStack {
                            Spacer()
                            if restoring { ProgressView().padding(.trailing, 6) }
                            Text(restoreTitle).fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(restoring || !model.isConnected || !model.projectSuspensionIsSupported)
                    .accessibilityIdentifier("restoreProject.restore")
                } footer: {
                    if !model.isConnected {
                        Text("Reconnect to your Mac to restore.")
                    } else if !model.projectSuspensionIsSupported {
                        Text("Update Chauffeur on your Mac to restore projects from this device.")
                    }
                }
            }
        }
        .navigationTitle(project?.name ?? "Suspended project")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshInventory() }
    }

    private func row(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title).font(.body.weight(.medium)).lineLimit(2)
                Spacer(minLength: 8)
                KindBadge(kind: session.kind)
            }
            let folder = model.inventory?.folder(session.folderID)
            SessionLocationLine(repository: folder?.name, branch: session.branch,
                                kind: session.worktreeID == nil ? .main : .worktree, isRepository: folder?.isRepository ?? true)
            if let error = session.restoreError {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                }
                .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func included(_ id: UUID) -> Binding<Bool> {
        Binding {
            !excluded.contains(id)
        } set: { included in
            if included { excluded.remove(id) } else { excluded.insert(id) }
        }
    }

    private var restoreTitle: String {
        if restoring { return "Restoring…" }
        if selected.count == sessions.count { return "Restore Project" }
        if selected.isEmpty { return "End Suspension" }
        return selected.count == 1 ? "Restore 1 Session" : "Restore \(selected.count) Sessions"
    }

    private func restore() async {
        guard !restoring else { return }
        restoring = true; failure = nil
        defer { restoring = false }
        // Every suspended session left out ends, so the Mac refuses if the project's suspended
        // sessions are no longer the ones shown here; the refreshed list then shows the change.
        let shown = sessions.map(\.id), chosen = selected.map(\.id)
        guard !shown.isEmpty else { return }
        do {
            let result = try await model.restoreProject(projectID, sessionIDs: chosen, shownSessionIDs: shown)
            if result.failures.isEmpty {
                dismiss()
            } else {
                failure = result.failures.count == 1 ? "“\(result.failures[0].title)” couldn't be resumed and stays suspended."
                    : "\(result.failures.count) sessions couldn't be resumed and stay suspended."
            }
        } catch RemoteClientError.timeout {
            failure = "The Mac is still restoring the project. Its sessions show up once they start."
        } catch {
            failure = SuspendProjectSheet.message(error)
        }
    }
}

#Preview("Restore") {
    let model = MobileAppModel.preview()
    return NavigationStack {
        RestoreProjectView(model: model, projectID: model.suspendedProjects[0].id)
    }
}
