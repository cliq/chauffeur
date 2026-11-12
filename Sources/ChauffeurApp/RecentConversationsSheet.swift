import SwiftUI
import AppKit
import ChauffeurCore

/// Lists the conversations agent CLIs recorded for a checkout, read from the
/// providers' own transcripts, so work stays findable after Chauffeur deletes
/// the finished session that ran it. A conversation resumes as a new session
/// with the project team's agent that uses the same provider profile.
struct RecentConversationsSheet: View {
    let row: CheckoutRow
    let project: Project
    /// False while the runtime is offline, the project is suspended or the checkout is unavailable.
    let canLaunch: Bool
    /// Shows a session that resumed, or already runs, a conversation.
    let showSession: (UUID) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [RecentConversation]?
    @State private var failure: String?
    @State private var resuming: String?
    @State private var resumeFailure: (id: String, message: String)?
    @State private var confirmingShare: RecentConversation?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent Conversations").font(.title3).fontWeight(.semibold)
                Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            Group {
                if let failure {
                    ContentUnavailableView("Conversations unavailable", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if let conversations, conversations.isEmpty {
                    ContentUnavailableView("No recent conversations", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("No Claude Code, Codex or OpenCode conversation recorded this checkout as its working directory."))
                } else if let conversations {
                    List(conversations) { conversationRow($0) }
                        .listStyle(.inset(alternatesRowBackgrounds: true))
                        .accessibilityIdentifier("recentConversations.list")
                } else {
                    ProgressView("Reading agent transcripts…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minHeight: 280, maxHeight: .infinity)
            HStack {
                Text("Read from each agent's own history. Chauffeur does not keep these.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(resuming != nil)
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
        .task { await load() }
        .confirmationDialog("Share this checkout?", isPresented: Binding(get: { confirmingShare != nil }, set: { if !$0 { confirmingShare = nil } }), titleVisibility: .visible) {
            Button("Resume and Share Checkout") { if let conversation = confirmingShare { resume(conversation, sharing: true) }; confirmingShare = nil }
            Button("Cancel", role: .cancel) { confirmingShare = nil }
        } message: {
            Text("\(liveAgents.isEmpty ? "Another agent is already working in this checkout." : "Already working here: \(liveAgents.map(\.title).joined(separator: ", ")).") Agents sharing a checkout can overwrite each other's changes.")
        }
    }

    private func load() async {
        do {
            let value = try await model.call("recentConversations", .object(["path": .string(row.path)]))
            conversations = try value.decode([RecentConversation].self)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func conversationRow(_ conversation: RecentConversation) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(conversation.updatedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                }
                if let prompt = conversation.prompt, prompt != conversation.title {
                    Text(prompt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(([conversation.kind.displayName] + [profileLabel(conversation)].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if let resumeFailure, resumeFailure.id == conversation.id {
                    Text(resumeFailure.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .help(details(conversation))
            resumeControl(conversation)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { primaryAction(conversation) }
        .contextMenu {
            if let session = owner(of: conversation) {
                Button("Show Session") { show(session.id) }
            } else {
                Button("Resume") { requestResume(conversation) }.disabled(resumeBlocker(conversation) != nil)
            }
            Divider()
            Button("Copy Conversation ID") { copy(conversation.id) }
            if let transcript = conversation.transcriptPath {
                Button("Reveal Transcript in Finder") { FilePanels.reveal(transcript) }
            }
        }
    }

    @ViewBuilder private func resumeControl(_ conversation: RecentConversation) -> some View {
        if resuming == conversation.id {
            ProgressView().controlSize(.small).frame(minWidth: 60)
        } else if let session = owner(of: conversation) {
            Button("Show") { show(session.id) }
                .help("“\(session.title)” is running this conversation")
                .accessibilityIdentifier("recentConversations.show")
        } else {
            let blocker = resumeBlocker(conversation)
            Button("Resume") { requestResume(conversation) }
                .disabled(blocker != nil || resuming != nil)
                .help(blocker ?? "Continue this conversation in a new session")
                .accessibilityIdentifier("recentConversations.resume")
        }
    }

    private func primaryAction(_ conversation: RecentConversation) {
        if let session = owner(of: conversation) { show(session.id) }
        else if resumeBlocker(conversation) == nil, resuming == nil { requestResume(conversation) }
    }

    /// A live session in this project already continuing the conversation.
    private func owner(of conversation: RecentConversation) -> Session? {
        model.snapshot.sessions.first { $0.projectID == project.id && $0.state.isLive && NativeConversation.same($0.nativeConversationID, conversation.id) }
    }

    private var currentProject: Project { model.project(project.id) ?? project }

    /// The project team's agent for this provider and profile, preferring the last one launched.
    private func agent(for conversation: RecentConversation) -> AgentPreset? {
        let store = model.snapshot.store
        guard let team = store.presetSets.first(where: { $0.value.id == currentProject.presetSetID })?.value else { return nil }
        let matches = store.agents(in: team).filter { agent in
            agent.kind == conversation.kind && conversation.configurationDirectory.map { Paths.canonical(agent.configurationDirectory) == $0 } != false
        }
        return matches.first { $0.id == currentProject.lastPresetID } ?? matches.first
    }

    private func resumeBlocker(_ conversation: RecentConversation) -> String? {
        guard canLaunch else { return "Sessions can't start in this checkout right now" }
        guard conversation.kind.provider?.validatesConversationID(conversation.id) == true else { return "This conversation's ID can't be resumed" }
        guard agent(for: conversation) != nil else {
            return "No agent in this project's team uses this \(conversation.kind.displayName) profile"
        }
        return nil
    }

    /// Agents running in this checkout now; the row was captured when the sheet opened.
    private var liveAgents: [Session] {
        let path = Paths.canonical(row.path)
        return model.snapshot.sessions.filter { $0.state.isLive && $0.launch.preset.kind.isAgent && Paths.canonical($0.launch.workingDirectory) == path }
    }

    private func requestResume(_ conversation: RecentConversation) {
        if liveAgents.isEmpty { resume(conversation, sharing: false) } else { confirmingShare = conversation }
    }

    private func resume(_ conversation: RecentConversation, sharing: Bool) {
        guard resuming == nil, let agent = agent(for: conversation) else { return }
        let project = currentProject
        let folder = project.folders.first { $0.id == row.folderID }
        let groups = project.groups.filter { !$0.archived }
        guard let group = groups.first(where: { $0.id == folder?.lastGroupID }) ?? groups.first(where: \.isDefault) ?? groups.first else {
            resumeFailure = (conversation.id, "Add an active group to this project before resuming"); return
        }
        resuming = conversation.id; resumeFailure = nil
        Task {
            defer { resuming = nil }
            do {
                let worktreeID = try await model.worktreeID(for: row, project: project)
                var request = LaunchRequest(projectID: project.id, groupID: group.id, presetID: agent.id, folderID: row.folderID, title: conversation.title,
                                            worktreeID: worktreeID, allowSharedCheckout: sharing, coordinationEnabled: folder?.lastCoordinationEnabled ?? false)
                request.resumeConversationID = conversation.id
                let session = try await model.call("launch", .from(request)).decode(Session.self)
                try await model.refresh()
                show(session.id)
            } catch {
                try? await model.refresh()
                // Another agent started here after the sheet checked; ask before sharing.
                if !sharing, (error as? ChauffeurError)?.code == "shared_checkout" { confirmingShare = conversation }
                else { resumeFailure = (conversation.id, error.localizedDescription) }
            }
        }
    }

    private func show(_ sessionID: UUID) {
        dismiss()
        showSession(sessionID)
    }

    /// The teams whose agents use this configuration directory, else the
    /// directory's name.
    private func profileLabel(_ conversation: RecentConversation) -> String? {
        guard let directory = conversation.configurationDirectory else { return nil }
        let store = model.snapshot.store
        let teams = store.presetSets.map(\.value).filter { team in
            store.agents(in: team, includeArchived: true).contains { $0.kind == conversation.kind && Paths.canonical($0.configurationDirectory) == directory }
        }.map(\.name).sorted()
        return teams.isEmpty ? URL(fileURLWithPath: directory).lastPathComponent : teams.joined(separator: ", ")
    }

    private func details(_ conversation: RecentConversation) -> String {
        var lines = ["\(conversation.kind.displayName) conversation \(conversation.id)"]
        if let started = conversation.startedAt { lines.append("Started \(started.formatted(date: .abbreviated, time: .shortened))") }
        lines.append("Last active \(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))")
        if let directory = conversation.configurationDirectory { lines.append(directory) }
        return lines.joined(separator: "\n")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
