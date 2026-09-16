import SwiftUI
import ChauffeurCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSet: UUID?
    @State private var newSet = false
    @State private var editedSet: PresetSet?
    @State private var newPreset = false
    @State private var deletingSet: Stored<PresetSet>?
    @State private var confirmingSetDeletion = false
    @State private var deleting = false
    @State private var editedPreset: AgentPreset?
    @State private var skillPreset: AgentPreset?
    @State private var retention = RetentionSettings()
    var body: some View {
        TabView {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Teams").font(.headline).padding(.horizontal, 12).padding(.vertical, 10)
                    List(selection: $selectedSet) {
                        ForEach(model.presetSets) { set in
                            HStack { Text(set.name); if set.archived { Text("Archived").font(.caption).foregroundStyle(.secondary) } }.tag(set.id)
                                .contextMenu {
                                    Button("Edit Team…") { editedSet = set }
                                    Button("Delete Team…", role: .destructive) { confirmDelete(set) }.disabled(deleting || !model.online)
                                }
                        }
                    }.listStyle(.sidebar).frame(maxHeight: .infinity)
                    Divider()
                    HStack { Button("Add Team…") { newSet = true }; if let selectedSet, let set = model.presetSets.first(where: { $0.id == selectedSet }) { Button("Edit…") { editedSet = set }.accessibilityIdentifier("preset-set.edit")
                        Button(role: .destructive) { confirmDelete(set) } label: { Image(systemName: "trash") }
                            .help("Delete Team…").accessibilityLabel("Delete Team…").accessibilityIdentifier("preset-set.delete").disabled(deleting || !model.online) } }.padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 200, idealWidth: 220, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    if let selectedSet, let set = model.presetSets.first(where: { $0.id == selectedSet }) {
                        HStack { Text(set.name).font(.title2); Spacer(); Text("Revision \(set.revision)").foregroundStyle(.secondary) }
                        Text("Agent presets select existing CLI configuration directories. Edits affect new launches in every linked project.").font(.callout).foregroundStyle(.secondary)
                        List(model.presets.filter { $0.setID == set.id }) { preset in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(preset.name).fontWeight(.semibold); Text(preset.kind.displayName).foregroundStyle(.secondary); if preset.archived { Text("Archived").font(.caption) }; Spacer(); Button("Edit…") { editedPreset = preset }.accessibilityIdentifier("preset.edit-\(preset.id.uuidString)") }
                                Text(preset.configurationDirectory).font(.caption).textSelection(.enabled)
                                Button("Chauffeur Skill…") { skillPreset = preset }
                                    .accessibilityIdentifier("preset-skill-\(preset.id.uuidString)")
                                if model.presets.filter({ Paths.canonical($0.configurationDirectory) == Paths.canonical(preset.configurationDirectory) }).count > 1 { Label("Configuration directory shared by multiple agent presets", systemImage: "person.2").font(.caption).foregroundStyle(.secondary) }
                                if set.defaultPresetID == preset.id { Text("Default agent preset").font(.caption).foregroundStyle(.tint) }
                            }.padding(.vertical, 6)
                        }
                        Button("Add Agent Preset…") { newPreset = true }.disabled(set.archived)
                    } else {
                        ContentUnavailableView("Choose a team", systemImage: "person.crop.rectangle.stack", description: Text("Create teams such as Personal or Client 1, then add Codex and Claude Code agent presets."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(20).frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("Agent Presets", systemImage: "person.crop.rectangle.stack") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            Form {
                Section("Background Service") {
                    ServiceHealthView()
                    LabeledContent("Build", value: AppBuild.current.rawValue)
                    if model.online, let identity = model.runtimeIdentity {
                        LabeledContent(model.runtimeConnectionVerified ? "Verified runtime" : "Custom runtime") {
                            Text(identity.executablePath).font(.caption).textSelection(.enabled)
                        }
                    }
                    HStack {
                        Button("Restart Service") { model.restartService() }.disabled(model.isRestartingService || model.isStoppingService)
                        Button(model.isStoppingService ? "Stopping…" : "Quit Service") { model.stopService() }
                            .disabled(!model.canStopService).accessibilityIdentifier("service.stop")
                        Button("Login Items Settings…") { model.openServiceSettings() }
                    }
                    Text("Quitting the service keeps agents running but pauses updates and coordination. Start it again here or reopen Chauffeur to reconnect.").font(.caption).foregroundStyle(.secondary)
                }
                NotificationSettingsSection()
                TerminalLauncherSettings()
                Section("Retention and Delegation") {
                    Toggle("Keep finished sessions", isOn: $retention.keepFinishedSessions)
                        .accessibilityIdentifier("settings.keep-finished-sessions")
                    Text("When off, closing an agent or shell tab stops the session and deletes its saved history. When on, closed sessions remain in Finished until you delete them.").font(.caption).foregroundStyle(.secondary)
                    TextField("Scrollback lines", value: $retention.scrollbackLines, format: .number)
                    TextField("Snapshot budget (bytes)", value: $retention.snapshotBudgetBytes, format: .number)
                    TextField("Completed message history (days)", value: $retention.completedMessageDays, format: .number)
                    Stepper("Live delegated children per parent: \(retention.maxLiveChildren)", value: $retention.maxLiveChildren, in: 1...32)
                    Button("Save Settings") { model.perform { _ = try await model.call("saveSettings", try .from(retention)) } }
                    Text("Saved terminal history: \(model.snapshot.snapshotStorage.files) files, \(ByteCountFormatter.string(fromByteCount: Int64(model.snapshot.snapshotStorage.bytes), countStyle: .file)).").font(.caption)
                    Text("History is captured every five seconds while the service is running. Older snapshots are removed to fit the disk budget, starting with ended sessions. Scrollback changes trim saved history immediately and apply to new live terminals. Queued and received messages and native CLI conversations are preserved.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    Button("Export Diagnostics…") { model.exportDiagnostics() }.disabled(model.isExportingDiagnostics)
                    Text("Exports paths, versions, session state, and error codes. Offline exports use the last received state and include its timestamp.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("Runtime", systemImage: "gearshape.2") }
        }.frame(minWidth: 740, idealWidth: 830, maxWidth: .infinity, minHeight: 480, idealHeight: 550, maxHeight: .infinity)
            .onAppear { selectedSet = selectedSet ?? model.presetSets.first?.id; retention = model.snapshot.settings }
            .confirmationDialog("Delete \(deletingSet?.value.name ?? "team")?", isPresented: $confirmingSetDeletion, titleVisibility: .visible) {
                Button("Delete Team", role: .destructive) { deleteSet() }
                Button("Cancel", role: .cancel) { deletingSet = nil }
            } message: {
                Text("Deletes this team and its agent preset definitions. Existing CLI configuration folders and session history are preserved.")
            }
            .sheet(isPresented: $newSet) { PresetSetEditor { id in selectedSet = id; newSet = false } }
            .sheet(item: $editedSet) { set in PresetSetEditor(presetSet: set) { id in selectedSet = id; editedSet = nil } }
            .sheet(isPresented: $newPreset) { if let selectedSet { PresetEditor(setID: selectedSet) } }
            .sheet(item: $editedPreset) { preset in PresetEditor(setID: preset.setID, preset: preset) }
            .sheet(item: $skillPreset) { preset in CoordinationSkillView(preset: preset) }
    }
    private func confirmDelete(_ set: PresetSet) {
        let projects = model.projects.filter { $0.presetSetID == set.id }
        guard projects.isEmpty else {
            model.error = "Switch these projects to another team before deleting: " + projects.map(\.name).sorted().joined(separator: ", ")
            return
        }
        deletingSet = model.snapshot.store.presetSets.first { $0.value.id == set.id }
        confirmingSetDeletion = deletingSet != nil
    }
    private func deleteSet() {
        guard let target = deletingSet, !deleting else { return }
        deleting = true
        Task {
            defer { deleting = false; deletingSet = nil }
            do {
                _ = try await model.call("deletePresetSet", .object(["setID": .string(target.value.id.uuidString), "version": .string(target.version)]))
                try await model.refresh()
                if selectedSet == target.value.id { selectedSet = model.presetSets.first?.id }
            } catch { model.error = error.localizedDescription }
        }
    }

}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in Text(appearance.label).tag(appearance) }
                }.pickerStyle(.segmented).accessibilityIdentifier("appearance-choice")
                Text("System follows your Mac’s appearance. Changes apply to all Chauffeur windows and terminal default colors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct PresetSetEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var presetSet: PresetSet?
    let completion: (UUID) -> Void
    @State private var name = ""
    @State private var defaultID: UUID?
    @State private var archived = false
    @State private var version: String?
    @State private var failure: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(presetSet == nil ? "Create Team" : "Edit Team").font(.title2)
            Form {
                TextField("Name", text: $name).accessibilityIdentifier("preset-set.name")
                if let presetSet {
                    Picker("Default agent preset", selection: $defaultID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.presets.filter { $0.setID == presetSet.id && !$0.archived }) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    }.accessibilityIdentifier("preset-set.default-preset")
                    Toggle("Archived", isOn: $archived)
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving); Spacer()
                Button(saving ? "Saving…" : "Save") {
                    guard !saving else { return }
                    saving = true; failure = nil
                    var value = presetSet ?? PresetSet(name: name); value.name = name; value.defaultPresetID = defaultID; value.archived = archived
                    Task { defer { saving = false }; do { try await model.save("savePresetSet", value, version: version); completion(value.id); dismiss() } catch { failure = error.localizedDescription } }
                }.keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("preset-set.save")
            }
        }.padding(24).frame(width: 470)
            .onAppear { name = presetSet?.name ?? ""; defaultID = presetSet?.defaultPresetID; archived = presetSet?.archived ?? false; version = model.snapshot.store.presetSets.first { $0.value.id == presetSet?.id }?.version }
    }
}

struct PresetEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let setID: UUID
    var preset: AgentPreset?
    @State private var name = ""
    @State private var kind: CLIKind = .codex
    @State private var executable = "codex"
    @State private var directory = ""
    @State private var arguments = ""
    @State private var archived = false
    @State private var version: String?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preset == nil ? "Create Agent Preset" : "Edit Agent Preset").font(.title2)
            Form {
                TextField("Agent preset name", text: $name).accessibilityIdentifier("preset.name")
                Picker("Agent", selection: $kind) { Text("Codex").tag(CLIKind.codex); Text("Claude Code").tag(CLIKind.claude) }
                    .onChange(of: kind) { _, value in if executable == "codex" || executable == "claude" { executable = value == .codex ? "codex" : "claude" } }
                HStack { TextField("Executable", text: $executable).accessibilityIdentifier("preset.executable"); Button("Choose…") { if let path = FilePanels.executable() { executable = path } }.accessibilityIdentifier("preset.choose-executable") }
                HStack {
                    TextField("Existing configuration directory", text: $directory).accessibilityIdentifier("preset.configuration-directory")
                    Button("Choose…") {
                        if let path = FilePanels.directory(title: "Choose an existing CLI configuration directory", startingAt: FileManager.default.homeDirectoryForCurrentUser, showsHiddenFiles: true) { directory = path }
                    }.accessibilityIdentifier("preset.choose-configuration-directory")
                }
                if preset != nil { Toggle("Archived", isOn: $archived) }
            }
            Text("Launch arguments").font(.headline)
            ArgumentEditor(text: $arguments).frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
            Text("Separate options with spaces or newlines. Quote values containing spaces, for example: --model \"model name\". Shell variables and commands are not expanded.").font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("Save Agent Preset") {
                    var value = preset ?? AgentPreset(setID: setID, name: name, kind: kind, executable: executable, configurationDirectory: directory)
                    value.name = name; value.kind = kind; value.executable = executable; value.configurationDirectory = (directory as NSString).expandingTildeInPath
                    value.archived = archived; value.integration = .unverified
                    Task { do { value.arguments = try ArgumentText.parse(arguments); try value.validate(); _ = try Paths.directory(value.configurationDirectory); try await model.save("savePreset", value, version: version); dismiss() } catch { failure = error.localizedDescription } }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || directory.isEmpty)
            }
        }.padding(24).frame(width: 650)
            .onAppear { name = preset?.name ?? ""; kind = preset?.kind ?? .codex; executable = preset?.executable ?? "codex"; directory = preset?.configurationDirectory ?? ""; arguments = ArgumentText.format(preset?.arguments ?? []); archived = preset?.archived ?? false; version = model.snapshot.store.presets.first { $0.value.id == preset?.id }?.version }
    }
}
