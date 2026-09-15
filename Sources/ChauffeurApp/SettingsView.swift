import SwiftUI
import ChauffeurCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedSet: UUID?
    @State private var newSet = false
    @State private var editedSet: PresetSet?
    @State private var newPreset = false
    @State private var editedPreset: AgentPreset?
    @State private var skillPreset: AgentPreset?
    @State private var retention = RetentionSettings()
    var body: some View {
        TabView {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Preset Sets").font(.headline).padding(.horizontal, 12).padding(.vertical, 10)
                    List(selection: $selectedSet) {
                        ForEach(model.presetSets) { set in
                            HStack { Text(set.name); if set.archived { Text("Archived").font(.caption).foregroundStyle(.secondary) } }.tag(set.id)
                                .contextMenu { Button("Edit Preset Set…") { editedSet = set } }
                        }
                    }.listStyle(.sidebar).frame(maxHeight: .infinity)
                    Divider()
                    HStack { Button("Add Set…") { newSet = true }; if let selectedSet, let set = model.presetSets.first(where: { $0.id == selectedSet }) { Button("Edit…") { editedSet = set } } }.padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 200, idealWidth: 220, maxWidth: 280, maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) {
                    if let selectedSet, let set = model.presetSets.first(where: { $0.id == selectedSet }) {
                        HStack { Text(set.name).font(.title2); Spacer(); Text("Revision \(set.revision)").foregroundStyle(.secondary) }
                        Text("Presets select existing CLI configuration directories. Edits affect new launches in every linked project.").font(.callout).foregroundStyle(.secondary)
                        List(model.presets.filter { $0.setID == set.id }) { preset in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(preset.name).fontWeight(.semibold); Text(preset.kind == .codex ? "Codex" : "Claude Code").foregroundStyle(.secondary); if preset.archived { Text("Archived").font(.caption) }; Spacer(); Button("Edit…") { editedPreset = preset } }
                                Text(preset.configurationDirectory).font(.caption).textSelection(.enabled)
                                Button("Chauffeur Skill…") { skillPreset = preset }
                                    .accessibilityIdentifier("preset-skill-\(preset.id.uuidString)")
                                if model.presets.filter({ Paths.canonical($0.configurationDirectory) == Paths.canonical(preset.configurationDirectory) }).count > 1 { Label("Configuration directory shared by multiple presets", systemImage: "person.2").font(.caption).foregroundStyle(.secondary) }
                                if set.defaultPresetID == preset.id { Text("Default preset").font(.caption).foregroundStyle(.tint) }
                            }.padding(.vertical, 6)
                        }
                        Button("Add Preset…") { newPreset = true }.disabled(set.archived)
                    } else {
                        ContentUnavailableView("Choose a preset set", systemImage: "person.crop.rectangle.stack", description: Text("Create sets such as Personal or Client 1, then add Codex and Claude Code presets."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(20).frame(minWidth: 450, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("Presets", systemImage: "person.crop.rectangle.stack") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
            Form {
                Section("Background Service") {
                    ServiceHealthView()
                    HStack { Button("Restart Service") { model.restartService() }.disabled(model.isRestartingService); Button("Login Items Settings…") { model.openServiceSettings() } }
                    Text("Agents remain running when Chauffeur's windows close. A runtime restart reconciles surviving terminal processes.").font(.caption).foregroundStyle(.secondary)
                }
                NotificationSettingsSection()
                TerminalLauncherSettings()
                Section("Retention and Delegation") {
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
            .sheet(isPresented: $newSet) { PresetSetEditor { id in selectedSet = id; newSet = false } }
            .sheet(item: $editedSet) { set in PresetSetEditor(presetSet: set) { id in selectedSet = id; editedSet = nil } }
            .sheet(isPresented: $newPreset) { if let selectedSet { PresetEditor(setID: selectedSet) } }
            .sheet(item: $editedPreset) { preset in PresetEditor(setID: preset.setID, preset: preset) }
            .sheet(item: $skillPreset) { preset in CoordinationSkillView(preset: preset) }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(presetSet == nil ? "Create Preset Set" : "Edit Preset Set").font(.title2)
            Form {
                TextField("Name", text: $name)
                if let presetSet {
                    Picker("Default preset", selection: $defaultID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.presets.filter { $0.setID == presetSet.id && !$0.archived }) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    }
                    Toggle("Archived", isOn: $archived)
                }
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                Button("Save") {
                    var value = presetSet ?? PresetSet(name: name); value.name = name; value.defaultPresetID = defaultID; value.archived = archived
                    Task { do { try await model.save("savePresetSet", value, version: version); completion(value.id); dismiss() } catch { failure = error.localizedDescription } }
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
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
                TextField("Preset name", text: $name)
                Picker("Agent", selection: $kind) { Text("Codex").tag(CLIKind.codex); Text("Claude Code").tag(CLIKind.claude) }
                    .onChange(of: kind) { _, value in if executable == "codex" || executable == "claude" { executable = value == .codex ? "codex" : "claude" } }
                HStack { TextField("Executable", text: $executable); Button("Choose…") { if let path = FilePanels.executable() { executable = path } } }
                HStack {
                    TextField("Existing configuration directory", text: $directory)
                    Button("Choose…") {
                        if let path = FilePanels.directory(title: "Choose an existing CLI configuration directory", startingAt: FileManager.default.homeDirectoryForCurrentUser, showsHiddenFiles: true) { directory = path }
                    }
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
                Button("Save Preset") {
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
