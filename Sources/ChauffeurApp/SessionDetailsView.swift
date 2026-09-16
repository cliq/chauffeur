import SwiftUI
import ChauffeurCore

struct SessionDetailsView: View {
    @EnvironmentObject private var model: AppModel
    let session: Session
    let project: Project
    @State private var confirmingStop = false
    @State private var confirmingForceStop = false
    private var messages: [Message] { model.snapshot.messages.filter { $0.senderID == session.id || $0.recipientID == session.id }.sorted { $0.createdAt > $1.createdAt } }
    private var delegations: [Delegation] { model.snapshot.delegations.filter { $0.parentID == session.id || $0.childID == session.id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Session Details").font(.title3)
                section("Context") {
                    detail("Title", session.title)
                    detail("State", session.state.label)
                    detail("Group", project.groups.first { $0.id == session.groupID }?.name ?? "Unavailable")
                    detail(session.launch.preset.kind.isAgent ? "Agent" : "Kind", session.launch.preset.kind.displayName)
                    if session.launch.preset.kind.isAgent {
                        detail("Agent Preset", session.launch.preset.name)
                        detail("Team", "\(session.launch.presetSetName) · revision \(session.launch.presetSetRevision)")
                        detail("Configuration directory", session.launch.configurationPath)
                    }
                    detail("Working directory", session.launch.workingDirectory)
                    ForEach(session.launch.additionalPaths, id: \.self) { detail("Additional repository", $0) }
                    if let worktree = model.snapshot.store.worktrees.first(where: { $0.value.id == session.worktreeID })?.value { detail("Branch", worktree.branch); detail("Base commit", worktree.baseCommit) }
                    if let error = session.error { Text(error).font(.callout).foregroundStyle(.orange) }
                }
                section("Execution") {
                    if session.state.isLive {
                        HStack {
                            Button("Interrupt") { model.perform { _ = try await model.call("interrupt", .object(["sessionID": .string(session.id.uuidString)])) } }
                            Button("Stop Session…", role: .destructive) { confirmingStop = true }
                        }
                        Button("Force Stop…", role: .destructive) { confirmingForceStop = true }.font(.caption)
                    } else if session.nativeConversationID != nil {
                        Button("Resume Conversation") { model.perform { _ = try await model.call("resume", .object(["sessionID": .string(session.id.uuidString)])) } }
                    }
                    Text(session.state.isLive ? "Closing the terminal view keeps this execution running. Stopping a parent preserves its children and their work." : "This execution has ended. Its launch settings and saved terminal history remain available.").font(.caption).foregroundStyle(.secondary)
                    if session.launch.preset.kind.isAgent && session.launch.preset.integration != .supported {
                        Text(session.launch.preset.integration == .unavailable ? "Coordination and semantic status are unavailable in basic terminal mode." : "CLI coordination is under validation. Fine-grained activity may be unknown; terminal silence is not completion.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                section("Messages (\(messages.count))") {
                    if session.pendingMessages > 0 { Text("\(session.pendingMessages) messages await the agent. Prompt an idle agent to read its Chauffeur inbox.").font(.callout).foregroundStyle(.orange) }
                    if messages.isEmpty { Text("No messages yet").foregroundStyle(.secondary) }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(name(message.senderID)) → \(name(message.recipientID))").font(.caption).fontWeight(.medium)
                            Text("\(groupName(message.scope.groupID)) · \(deliveryLabel(message.state))").font(.caption).foregroundStyle(.secondary)
                            Text(message.body).textSelection(.enabled)
                            ForEach(message.references, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            Text(message.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            if message.state == .queued { Button("Cancel Queued Message") { model.perform { _ = try await model.call("cancelMessage", .object(["messageID": .string(message.id.uuidString)])) } }.font(.caption) }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                section("Delegations") {
                    if delegations.isEmpty { Text("No delegated sessions").foregroundStyle(.secondary) }
                    ForEach(delegations) { delegation in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(name(delegation.parentID)) → \(name(delegation.childID))").fontWeight(.medium)
                            Text(delegation.task).textSelection(.enabled)
                            Text(delegation.state.rawValue).font(.caption).foregroundStyle(.secondary)
                            if let result = delegation.result { Text(result).textSelection(.enabled) }
                            if let error = delegation.error { Text(error).foregroundStyle(.orange) }
                            if let id = delegation.worktreeID, let tree = model.snapshot.store.worktrees.first(where: { $0.value.id == id })?.value { detail("Worktree", tree.path) }
                        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                DisclosureGroup("Launch Snapshot") {
                    VStack(alignment: .leading, spacing: 10) {
                        detail("Session ID", session.id.uuidString)
                        detail("Executable", session.launch.executablePath)
                        detail("CLI version", session.launch.executableVersion)
                        detail("Native conversation ID", session.nativeConversationID ?? "Not available")
                        detail("Process ID", session.processID.map(String.init) ?? "Not available")
                        detail("Arguments", session.launch.preset.arguments.joined(separator: "\n"))
                        detail("Launched", session.launch.launchedAt.formatted())
                    }.padding(.top, 10)
                }
            }.padding(18)
        }.background(.background)
            .confirmationDialog("Stop \(session.title)?", isPresented: $confirmingStop, titleVisibility: .visible) {
                Button("Stop Session", role: .destructive) { stop(force: false) }
            } message: { Text("This sends a graceful stop request to this execution. Delegated children keep running.") }
            .confirmationDialog("Force stop \(session.title)?", isPresented: $confirmingForceStop, titleVisibility: .visible) {
                Button("Force Stop", role: .destructive) { stop(force: true) }
            } message: { Text("This closes this execution's terminal immediately. Unsaved work inside the CLI may be lost.") }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 10) { Text(title).font(.headline); content() } }
    private func detail(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
    private func name(_ id: UUID) -> String { model.session(id)?.title ?? String(id.uuidString.prefix(8)) }
    private func groupName(_ id: UUID) -> String { project.groups.first { $0.id == id }?.name ?? "Group unavailable" }
    private func deliveryLabel(_ state: DeliveryState) -> String {
        switch state { case .queued: "Queued"; case .received: "Received by integration"; case .acknowledged: "Acknowledged by agent"; case .failed: "Failed"; case .cancelled: "Cancelled" }
    }
    private func stop(force: Bool) { model.perform { _ = try await model.call("stop", .object(["sessionID": .string(session.id.uuidString), "force": .bool(force)])) } }
}
