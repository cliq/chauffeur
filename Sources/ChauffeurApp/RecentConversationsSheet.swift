import SwiftUI
import AppKit
import ChauffeurCore

/// Lists the conversations agent CLIs recorded for a checkout, read from the
/// providers' own transcripts, so work stays findable after Chauffeur deletes
/// the finished session that ran it.
struct RecentConversationsSheet: View {
    let row: CheckoutRow
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var conversations: [RecentConversation]?
    @State private var failure: String?

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
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
        .task { await load() }
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
        }
        .padding(.vertical, 4)
        .help(details(conversation))
        .contextMenu {
            Button("Copy Conversation ID") { copy(conversation.id) }
            if let transcript = conversation.transcriptPath {
                Button("Reveal Transcript in Finder") { FilePanels.reveal(transcript) }
            }
        }
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
