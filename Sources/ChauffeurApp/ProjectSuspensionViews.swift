import SwiftUI
import ChauffeurCore

/// Confirms suspending a project: which agents stop and resume later, which are
/// interrupted mid-turn, which shells close, and what has to be closed first.
struct SuspendProjectSheet: View {
    let project: Project
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: ProjectSuspensionPlan?
    @State private var failure: String?
    @State private var suspending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Suspend “\(project.name)”?").font(.title3).fontWeight(.semibold)
                Text("Stops the project's Claude Code and Codex sessions once each has a saved conversation, and closes its shells. Restoring the project resumes every agent where it left off.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let plan {
                    List { planSections(plan) }
                        .listStyle(.inset(alternatesRowBackgrounds: false))
                        .accessibilityIdentifier("suspendProject.plan")
                } else if let failure {
                    ContentUnavailableView("Can't check this project", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView("Checking each agent's conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minHeight: 220, maxHeight: .infinity)
            if let fallbacks = plan?.agents.filter({ !$0.conversationRecorded }), !fallbacks.isEmpty, plan?.canSuspend == true {
                Label(fallbacks.count == 1 ? "One agent's conversation was found by searching transcripts and may not be the one it was running."
                      : "\(fallbacks.count) agents' conversations were found by searching transcripts and may not be the ones they were running.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("suspendProject.fallbackWarning")
            }
            if let failure, plan != nil {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("suspendProject.error")
            }
            HStack {
                if suspending { ProgressView().controlSize(.small); Text("Suspending…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(suspending)
                Button(suspendTitle) { Task { await suspend() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan?.canSuspend != true || suspending || !model.online)
                    .accessibilityIdentifier("suspendProject.confirm")
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .task { await load() }
    }

    @ViewBuilder
    private func planSections(_ plan: ProjectSuspensionPlan) -> some View {
        if !plan.blockers.isEmpty {
            Section {
                ForEach(plan.blockers) { blocker in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(blocker.title).fontWeight(.medium)
                            Text(blocker.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Close or wait for these first")
            }
        }
        if !plan.agents.isEmpty {
            Section("Agents to suspend") {
                ForEach(plan.agents) { agent in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.title).fontWeight(.medium)
                            Text(agentDetail(agent)).font(.caption).foregroundStyle(.secondary)
                            if !agent.conversationRecorded {
                                Label("Its recorded conversation has no transcript, so restoring resumes the newest conversation found in this checkout. Check it's the right one after restoring.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        switch agent.activity {
                        case .working: Text("Working · will be interrupted").font(.caption).foregroundStyle(.orange)
                        case .unknown: Text("May be working").font(.caption).foregroundStyle(.secondary)
                        case .idle: EmptyView()
                        }
                    }
                }
            }
        }
        if !plan.shells.isEmpty {
            Section("Shells to close") {
                ForEach(plan.shells) { shell in
                    Label(shell.title, systemImage: "terminal")
                }
            }
        }
        if plan.agents.isEmpty && plan.blockers.isEmpty {
            Text("No Claude Code or Codex sessions are running in this project.").foregroundStyle(.secondary)
        }
    }

    private func agentDetail(_ agent: ProjectSuspensionPlan.Agent) -> String {
        let conversation = agent.conversationRecorded ? "Resumes its conversation" : "Resumes a conversation found in the checkout's transcripts"
        return "\(agent.kind.displayName) · \(conversation)"
    }

    private var suspendTitle: String {
        plan?.busyAgents.isEmpty == false ? "Interrupt and Suspend" : "Suspend"
    }

    private func load() async {
        failure = nil
        do {
            plan = try await model.call("suspendPlan", .object(["projectID": .string(project.id.uuidString)])).decode(ProjectSuspensionPlan.self)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func suspend() async {
        guard let plan else { return }
        suspending = true; failure = nil
        defer { suspending = false }
        // Each agent gets a grace period to quit before its terminal is forced closed.
        let timeout = 30 + plan.agents.count * 10 + plan.shells.count * 5
        do {
            // Consent covers only the agents this sheet showed as working.
            _ = try await model.call("suspendProject", .object(["projectID": .string(project.id.uuidString), "interruptBusy": .bool(!plan.busyAgents.isEmpty)]),
                                     responseTimeout: timeout)
            try? await model.refresh()
            dismiss()
        } catch let error as ChauffeurError where error.code == "busy_sessions" {
            self.plan = nil
            await load()
            failure = "An agent started working. Check the list and confirm again."
        } catch {
            failure = error.localizedDescription
            try? await model.refresh()
        }
    }
}

/// Fills a suspended project's window: the sessions restoring resumes, each of which
/// can be left out, and the Restore button.
struct ProjectSuspendedView: View {
    let project: Project
    /// The suspended sessions, oldest first.
    let sessions: [Session]
    let online: Bool
    @EnvironmentObject private var model: AppModel
    @State private var excluded = Set<UUID>()
    @State private var restoring = false
    @State private var failure: String?

    private var selected: [Session] { sessions.filter { !excluded.contains($0.id) } }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "pause.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
            Text("Project suspended").font(.title2).fontWeight(.semibold)
            if let since = sessions.compactMap(\.suspendedAt).min() {
                Text("Suspended \(since.formatted(.relative(presentation: .named))). Restoring resumes each agent's conversation in its checkout.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            List {
                ForEach(sessions) { session in
                    Toggle(isOn: Binding(get: { !excluded.contains(session.id) }, set: { included in
                        if included { excluded.remove(session.id) } else { excluded.insert(session.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).fontWeight(.medium)
                            Text(detail(session)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if let error = session.error {
                                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(restoring)
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxWidth: 560, minHeight: 120, maxHeight: 340)
            .accessibilityIdentifier("projectSuspended.sessions")
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                if restoring { ProgressView().controlSize(.small) }
                Button(restoreTitle) { Task { await restore() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!online || restoring)
                    .accessibilityIdentifier("projectSuspended.restore")
            }
            Text(online ? "Sessions left unticked stay in the project as ended sessions you can resume later." : "Reconnect to the background service to restore.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var restoreTitle: String {
        if restoring { return "Restoring…" }
        if selected.count == sessions.count { return "Restore Project" }
        if selected.isEmpty { return "End Suspension" }
        return selected.count == 1 ? "Restore 1 Session" : "Restore \(selected.count) Sessions"
    }

    /// The agent, and where it runs: the repository, plus the worktree folder when it isn't the main checkout.
    private func detail(_ session: Session) -> String {
        var parts = [session.launch.preset.kind.displayName]
        let checkout = URL(fileURLWithPath: session.launch.workingDirectory).lastPathComponent
        if let folder = project.folders.first(where: { $0.id == session.folderID }) {
            let repository = URL(fileURLWithPath: folder.canonicalPath).lastPathComponent
            parts.append(Paths.canonical(session.launch.workingDirectory) == folder.canonicalPath ? repository : "\(repository) · \(checkout)")
        } else {
            parts.append(checkout)
        }
        return parts.joined(separator: " · ")
    }

    private func restore() async {
        let ids = selected.map(\.id)
        restoring = true; failure = nil
        defer { restoring = false }
        do {
            let value = try await model.call("restoreProject", .object(["projectID": .string(project.id.uuidString), "sessionIDs": .array(ids.map { .string($0.uuidString) })]),
                                             responseTimeout: 60 + ids.count * 30)
            let result = try value.decode(ProjectRestoreResult.self)
            if !result.failures.isEmpty {
                failure = result.failures.count == 1 ? "“\(result.failures[0].title)” couldn't be resumed and stays suspended."
                    : "\(result.failures.count) sessions couldn't be resumed and stay suspended."
            }
        } catch {
            failure = error.localizedDescription
        }
        try? await model.refresh()
    }
}
