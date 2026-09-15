import SwiftUI
import ChauffeurCore

struct SessionLaunchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: Project
    let initialGroupID: UUID?
    let initialFolderID: UUID?
    let completion: (UUID) -> Void
    @State private var title = ""
    @State private var task = ""
    @State private var groupID: UUID?
    @State private var presetID: UUID?
    @State private var folderID: UUID?
    @State private var worktreeID: UUID?
    @State private var additional = Set<UUID>()
    @State private var shared = false
    @State private var coordination = true
    @State private var launching = false
    @State private var failure: String?
    @State private var retryKey = UUID()
    @State private var sentRequest: LaunchRequest?
    private var presets: [AgentPreset] { model.presets.filter { $0.setID == project.presetSetID && !$0.archived } }
    private var preset: AgentPreset? { presets.first { $0.id == presetID } }
    private var folder: ProjectFolder? { project.folders.first { $0.id == folderID && $0.registered } }
    private var worktrees: [Worktree] { model.snapshot.store.worktrees.map(\.value).filter { $0.projectID == project.id && $0.folderID == folderID && $0.registered } }
    private var primaryPath: String { worktrees.first { $0.id == worktreeID }?.path ?? folder?.canonicalPath ?? "" }
    private var sharing: [Session] { model.snapshot.sessions.filter { $0.state.isLive && $0.launch.workingDirectory == primaryPath } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.title2)
            Form {
                TextField("Title (optional)", text: $title)
                Picker("Group", selection: $groupID) {
                    Text("Choose a group").tag(UUID?.none)
                    ForEach(project.groups.filter { !$0.archived }) { group in Text(group.name).tag(Optional(group.id)) }
                }
                Picker("Agent preset", selection: $presetID) {
                    Text("Choose a preset").tag(UUID?.none)
                    ForEach(presets) { preset in Text("\(preset.name) · \(preset.kind == .codex ? "Codex" : "Claude Code")").tag(Optional(preset.id)) }
                }
                if let preset { LabeledContent("Configuration", value: preset.configurationDirectory).textSelection(.enabled) }
                Picker("Primary folder", selection: $folderID) {
                    Text("Choose a folder").tag(UUID?.none)
                    ForEach(project.folders.filter(\.registered)) { folder in Text(folder.name).tag(Optional(folder.id)) }
                }.onChange(of: folderID) { _, _ in worktreeID = nil; shared = false }
                Picker("Checkout", selection: $worktreeID) {
                    Text("Use existing registered folder").tag(UUID?.none)
                    ForEach(worktrees) { worktree in Text("\(worktree.branch) · \(worktree.availability.rawValue)").tag(Optional(worktree.id)) }
                }
            }
            if !primaryPath.isEmpty { Text(primaryPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            if !sharing.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Label("This checkout is in use", systemImage: "person.2.fill").fontWeight(.medium)
                    ForEach(sharing) { session in Text("\(model.project(session.projectID)?.name ?? "Project") · \(session.title)").font(.caption) }
                    Toggle("Share this checkout with these sessions", isOn: $shared)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if project.folders.filter({ $0.registered && $0.id != folderID }).count > 0 {
                DisclosureGroup("Additional repository access") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(project.folders.filter { $0.registered && $0.id != folderID }) { folder in
                            Toggle(isOn: Binding(get: { additional.contains(folder.id) }, set: { if $0 { additional.insert(folder.id) } else { additional.remove(folder.id) } })) {
                                VStack(alignment: .leading) { Text(folder.name); Text(folder.canonicalPath).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Text("Additional repositories use these existing paths. A worktree for the primary repository does not isolate them.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                }
            }
            Text("Initial task (optional)").font(.headline)
            TextEditor(text: $task).frame(height: 100).border(.separator)
            Toggle("Enable Chauffeur messaging and delegation", isOn: $coordination)
            Text(coordination ? "CLI integration is under compatibility validation. Profile names identify configuration directories; they do not verify an account." : "Basic terminal mode: Chauffeur communication and semantic status signals are unavailable.").font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if sentRequest != nil && !launching { Button("Retry Same Request") { launch(retry: true) } }
                Button(launching ? "Launching…" : "Launch Session") { launch(retry: false) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(launching || presetID == nil || folderID == nil || groupID == nil || (!sharing.isEmpty && !shared))
            }
        }.padding(24).frame(width: 650)
            .onAppear {
                groupID = initialGroupID ?? project.groups.first(where: \.isDefault)?.id
                let choices = presets.map(\.id)
                presetID = project.lastPresetID.flatMap { choices.contains($0) ? $0 : nil } ?? model.presetSets.first { $0.id == project.presetSetID }?.defaultPresetID.flatMap { choices.contains($0) ? $0 : nil } ?? presets.first?.id
                folderID = initialFolderID ?? project.folders.first(where: \.registered)?.id
            }
    }
    private func launch(retry: Bool) {
        guard let groupID, let presetID, let folderID else { return }
        let request: LaunchRequest
        if retry, let previous = sentRequest { request = previous }
        else {
            retryKey = UUID()
            request = LaunchRequest(projectID: project.id, groupID: groupID, presetID: presetID, folderID: folderID, title: title.isEmpty ? "\(preset?.name ?? "Agent") · \(folder?.name ?? "Session")" : title, worktreeID: worktreeID, additionalFolderIDs: additional.filter { $0 != folderID }.sorted { $0.uuidString < $1.uuidString }, task: task.isEmpty ? nil : task, allowSharedCheckout: shared, coordinationEnabled: coordination, retryKey: retryKey)
            sentRequest = request
        }
        launching = true; failure = nil
        Task {
            do {
                let session = try await model.call("launch", .from(request)).decode(Session.self)
                try await model.refresh()
                completion(session.id); dismiss()
            } catch {
                failure = error.localizedDescription; launching = false; try? await model.refresh()
            }
        }
    }
}
