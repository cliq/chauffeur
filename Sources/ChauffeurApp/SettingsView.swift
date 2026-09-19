import SwiftUI
import ChauffeurCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var setupProjectTeam: UUID?
    @State private var selectedSet: UUID?
    @State private var newSet = false
    @State private var editedSet: PresetSet?
    @State private var newPreset = false
    @State private var deletingSet: Stored<PresetSet>?
    @State private var confirmingSetDeletion = false
    @State private var deleting = false
    @State private var editedBase: BaseAgentPreset?
    @State private var editedPreset: AgentPreset?
    @State private var skillPreset: AgentPreset?
    @State private var revealedPresetID: UUID?
    @State private var retention = RetentionSettings()
    var body: some View {
        TabView {
            BaseAgentPresetsView().tabItem { Label("Agent Presets", systemImage: "terminal") }
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Teams").font(.headline).padding(.horizontal, 12).padding(.vertical, 10)
                    List(selection: $selectedSet) {
                        ForEach(model.presetSets) { set in
                            HStack { Text(set.name); if set.isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }; if set.archived { Text("Archived").font(.caption).foregroundStyle(.secondary) } }.tag(set.id)
                                .contextMenu {
                                    Button("Edit Team…") { editedSet = set }
                                    Button("Make Default Team") { makeDefault(set) }.disabled(set.isDefault || set.archived || !model.online)
                                    Button("Delete Team…", role: .destructive) { confirmDelete(set) }.disabled(deleting || !model.online)
                                }
                        }
                    }.listStyle(.sidebar).frame(maxHeight: .infinity)
                    Divider()
                    HStack { Button("Add Team…") { newSet = true }; if let selectedSet, let set = model.presetSets.first(where: { $0.id == selectedSet }) { Button("Edit…") { editedSet = set }.accessibilityIdentifier("preset-set.edit")
                        if !set.isDefault, !set.archived { Button("Make Default") { makeDefault(set) }.disabled(!model.online).accessibilityIdentifier("preset-set.make-default") }
                        Button(role: .destructive) { confirmDelete(set) } label: { Image(systemName: "trash") }
                            .help("Delete Team…").accessibilityLabel("Delete Team…").accessibilityIdentifier("preset-set.delete").disabled(deleting || !model.online) } }.padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 200, idealWidth: 220, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    if let selectedSet, let set = model.presetSets.first(where: { $0.id == selectedSet }) {
                        HStack { Text(set.name).font(.title2); Spacer(); Text("Revision \(set.revision)").foregroundStyle(.secondary) }
                        Text(set.agentSelection == .allBase ? "Uses all agent presets. Changes to agent presets apply to new launches." : "Custom presets are independent copies. Team directories apply to every agent.").font(.callout).foregroundStyle(.secondary)
                        ForEach(CLIKind.allCases.filter(\.isAgent), id: \.self) { kind in
                            LabeledContent {
                                Text(set.configurationDirectory(for: kind)).font(.caption).textSelection(.enabled)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind == .claude ? "Claude config folder" : "Codex config folder")
                                    Text(ShellAgentEnvironment.variableName(for: kind)!).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        AgentPresetList(set: set, revealedPresetID: $revealedPresetID, edit: { agent in
                            if set.agentSelection == .allBase { editedBase = model.snapshot.store.baseAgentPresets.first { $0.value.id == agent.id }?.value }
                            else { editedPreset = agent }
                        }, showSkill: { skillPreset = $0 })
                        if set.agentSelection != .allBase { Button("Add Agent…") { newPreset = true }.disabled(set.archived) }
                    } else {
                        ContentUnavailableView("Choose a team", systemImage: "person.crop.rectangle.stack", description: Text("Create teams such as Personal or Client 1, then choose their configuration directories."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(20).frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("Teams", systemImage: "person.crop.rectangle.stack") }
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
                    Text("When off, successfully exited sessions and closed tabs are removed with their saved history. Failed sessions remain available for diagnosis. When on, finished sessions remain until you delete them.").font(.caption).foregroundStyle(.secondary)
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
            Form { RemoteAccessSettingsSection() }
                .formStyle(.grouped).tabItem { Label("Remote Access", systemImage: "iphone") }
        }.frame(minWidth: 740, idealWidth: 830, maxWidth: .infinity, minHeight: 480, idealHeight: 550, maxHeight: .infinity)
            .onAppear { selectedSet = selectedSet ?? model.presetSets.first?.id; retention = model.snapshot.settings }
            .confirmationDialog("Delete \(deletingSet?.value.name ?? "team")?", isPresented: $confirmingSetDeletion, titleVisibility: .visible) {
                Button("Delete Team", role: .destructive) { deleteSet() }
                Button("Cancel", role: .cancel) { deletingSet = nil }
            } message: {
                Text("Deletes this team and its agent preset definitions. Existing CLI configuration folders and session history are preserved.")
            }
            .sheet(isPresented: $newSet, onDismiss: {
                if let id = setupProjectTeam {
                    setupProjectTeam = nil
                    model.projectCreation = AppModel.ProjectCreation(teamID: id)
                    openWindow(id: "welcome")
                }
            }) { OnboardingWizard { id in if let id { selectedSet = id; setupProjectTeam = id }; newSet = false } }
            .sheet(item: $editedSet) { set in PresetSetEditor(presetSet: set) { id in selectedSet = id; editedSet = nil } }
            .sheet(isPresented: $newPreset) { if let selectedSet { AddBaseAgentView(teamID: selectedSet) { revealedPresetID = $0 } } }
            .sheet(item: $editedBase) { base in BaseAgentEditor(preset: base) }
            .sheet(item: $editedPreset) { preset in PresetEditor(setID: preset.setID, preset: preset) { revealedPresetID = $0 } }
            .sheet(item: $skillPreset) { preset in CoordinationSkillView(preset: preset) }
    }
    /// Flags the team as default; the runtime clears the flag on the previous default.
    private func makeDefault(_ set: PresetSet) {
        var value = set; value.isDefault = true
        let version = model.snapshot.store.presetSets.first { $0.value.id == set.id }?.version
        model.perform { try await model.save("savePresetSet", value, version: version) }
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

/// Agent presets of one team. A plain scroll view instead of `List`: the
/// table-backed list mis-measured freshly inserted multi-line rows and clipped
/// them to a single control, and it offered no way to reveal a saved preset.
struct AgentPresetList: View {
    @EnvironmentObject private var model: AppModel
    let set: PresetSet
    @Binding var revealedPresetID: UUID?
    let edit: (AgentPreset) -> Void
    let showSkill: (AgentPreset) -> Void
    private var presets: [AgentPreset] { model.snapshot.store.agents(in: set, includeArchived: true) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if presets.isEmpty {
                        Text("No agents available. Create an agent preset in Agent Presets, or choose Add Agent… in Custom mode.").foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(presets) { preset in
                        row(preset).id(preset.id)
                        if preset.id != presets.last?.id { Divider() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator, lineWidth: 1))
            .accessibilityIdentifier("preset.list")
            .onChange(of: revealedPresetID) { _, id in reveal(id, with: proxy) }
            .onChange(of: presets.map(\.id)) { _, ids in if let id = revealedPresetID, ids.contains(id) { reveal(id, with: proxy) } }
        }
    }
    private func row(_ preset: AgentPreset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(preset.name).fontWeight(.semibold)
                AgentKindBadge(kind: preset.kind)
                if preset.archived { Text("Archived").font(.caption) }
                Spacer()
                Button(set.agentSelection == .allBase ? "Edit Agent Preset…" : "Edit…") { edit(preset) }.accessibilityIdentifier("preset.edit-\(preset.id.uuidString)")
            }
            Text(preset.configurationDirectory).font(.caption).textSelection(.enabled)
            Button("Chauffeur Skill…") { showSkill(preset) }.accessibilityIdentifier("preset-skill-\(preset.id.uuidString)")
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityIdentifier("preset.row-\(preset.id.uuidString)")
    }
    /// The saved preset is in the snapshot before the editor closes; wait for
    /// the sheet to dismiss so the row is laid out before scrolling to it.
    private func reveal(_ id: UUID?, with proxy: ScrollViewProxy) {
        guard let id, presets.contains(where: { $0.id == id }) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            revealedPresetID = nil
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
    @State private var selection: AgentSelection = .allBase
    @State private var claudeDirectory = ""
    @State private var codexDirectory = ""
    @State private var archived = false
    @State private var isDefault = false
    @State private var version: String?
    @State private var failure: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(presetSet == nil ? "Create Team" : "Edit Team").font(.title2)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Name")
                    TextField("Name", text: $name).labelsHidden().accessibilityIdentifier("preset-set.name")
                }
                Picker("Agents", selection: $selection) {
                    Text("Use all agent presets").tag(AgentSelection.allBase)
                    Text("Custom").tag(AgentSelection.custom)
                }.accessibilityIdentifier("team.agent-selection")
                Text(selection == .allBase ? "Agent preset changes apply automatically to future launches." : "Add independent copies of agent presets and customize them.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                directoryField("Claude config folder", variable: "CLAUDE_CONFIG_DIR", value: $claudeDirectory)
                directoryField("Codex config folder", variable: "CODEX_HOME", value: $codexDirectory)
                Text("Leave a directory blank to use the agent’s normal default. Both values apply to new shell terminals.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if presetSet != nil {
                    Toggle("Archived", isOn: $archived).disabled(isDefault)
                }
                Toggle("Default team", isOn: $isDefault).disabled(presetSet?.isDefault == true).accessibilityIdentifier("preset-set.default-team")
                if presetSet?.isDefault == true { Text("Make another team the default to change this.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving); Spacer()
                Button(saving ? "Saving…" : "Save") {
                    guard !saving else { return }
                    saving = true; failure = nil
                    var value = presetSet ?? PresetSet(name: name, agentSelection: selection); value.agentSelection = selection; value.configurationDirectories = ["claude": (claudeDirectory as NSString).expandingTildeInPath, "codex": (codexDirectory as NSString).expandingTildeInPath]; value.name = name; value.archived = archived; value.isDefault = isDefault
                    Task { defer { saving = false }; do { try await model.save("savePresetSet", value, version: version); completion(value.id); dismiss() } catch { failure = error.localizedDescription } }
                }.keyboardShortcut(.defaultAction).disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("preset-set.save")
            }
        }.frame(width: 552, alignment: .leading).padding(24)
            .onAppear { selection = presetSet?.agentSelection ?? .allBase; claudeDirectory = presetSet?.configurationDirectories?["claude"] ?? ""; codexDirectory = presetSet?.configurationDirectories?["codex"] ?? ""; name = presetSet?.name ?? ""; archived = presetSet?.archived ?? false; isDefault = presetSet?.isDefault ?? model.presetSets.allSatisfy(\.archived); version = model.snapshot.store.presetSets.first { $0.value.id == presetSet?.id }?.version }
    }
    private func directoryField(_ title: String, variable: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(variable).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                TextField(title, text: value).labelsHidden()
                    .accessibilityIdentifier("team.\(variable)")
                    .frame(minWidth: 0, maxWidth: .infinity)
                Button("Choose…") {
                    if let path = FilePanels.directory(title: "Choose \(title)", startingAt: FileManager.default.homeDirectoryForCurrentUser, showsHiddenFiles: true) { value.wrappedValue = path }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PresetEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let setID: UUID
    var preset: AgentPreset?
    var completion: ((UUID) -> Void)? = nil
    @State private var name = ""
    @State private var kind: CLIKind = .codex
    @State private var executable = "codex"
    @State private var arguments = ""
    @State private var archived = false
    @State private var version: String?
    @State private var failure: String?
    private var teamName: String? { model.presetSets.first { $0.id == setID }?.name }
    private var title: String {
        let action = preset == nil ? "Create Agent Preset" : "Edit Agent Preset"
        return teamName.map { "\(action) (\($0))" } ?? action
    }
    /// A blank custom name falls back to the agent's own name.
    private var effectiveName: String {
        let custom = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? kind.displayName : custom
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).accessibilityIdentifier("preset.title")
            Form {
                Picker("Agent", selection: $kind) { Text("Codex").tag(CLIKind.codex); Text("Claude Code").tag(CLIKind.claude) }
                    .accessibilityIdentifier("preset.agent")
                    .onChange(of: kind) { _, value in if executable == "codex" || executable == "claude" { executable = value == .codex ? "codex" : "claude" } }
                TextField("Name", text: $name, prompt: Text(kind.displayName)).accessibilityIdentifier("preset.name")
                Text("Optional. Leave blank to name the agent preset “\(kind.displayName)”.").font(.caption).foregroundStyle(.secondary)
                HStack { TextField("Executable", text: $executable).accessibilityIdentifier("preset.executable"); Button("Choose…") { if let path = FilePanels.executable() { executable = path } }.accessibilityIdentifier("preset.choose-executable") }
                Text("Configuration directory comes from the team.").font(.caption).foregroundStyle(.secondary)
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
                    var value = preset ?? AgentPreset(setID: setID, name: effectiveName, kind: kind, executable: executable, configurationDirectory: "")
                    value.name = effectiveName; value.kind = kind; value.executable = executable; value.configurationDirectory = ""
                    value.archived = archived; value.integration = .unverified
                    Task { do { value.arguments = try ArgumentText.parse(arguments); try value.validate(); try await model.save("savePreset", value, version: version); completion?(value.id); dismiss() } catch { failure = error.localizedDescription } }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("preset.save")
            }
        }.padding(24).frame(width: 650)
            .onAppear { name = preset?.name ?? ""; kind = preset?.kind ?? .codex; executable = preset?.executable ?? "codex"; arguments = ArgumentText.format(preset?.arguments ?? []); archived = preset?.archived ?? false; version = model.snapshot.store.presets.first { $0.value.id == preset?.id }?.version }
    }
}
