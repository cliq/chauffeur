import SwiftUI
import ChauffeurCore

struct BaseAgentPresetsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var editing: BaseAgentPreset?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shared Agent Presets").font(.title2)
            Text("Define launch commands once. Teams using all shared presets inherit changes; custom copies remain independent.")
                .foregroundStyle(.secondary)
            List(model.snapshot.store.baseAgentPresets.map(\.value).sorted { $0.name < $1.name }) { preset in
                HStack {
                    VStack(alignment: .leading) {
                        Text(preset.name).font(.headline)
                        Text(preset.kind.displayName + " · " + ArgumentText.format([preset.executable] + preset.arguments)).font(.caption).textSelection(.enabled)
                    }
                    Spacer()
                    if preset.archived { Text("Archived").foregroundStyle(.secondary) }
                    Button("Edit…") { editing = preset }
                }.padding(.vertical, 6)
            }
            Button("Add Shared Agent Preset…") { adding = true }.disabled(!model.online)
        }.padding(20)
            .sheet(isPresented: $adding) { BaseAgentEditor() }
            .sheet(item: $editing) { BaseAgentEditor(preset: $0) }
    }
}

struct BaseAgentEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var preset: BaseAgentPreset?
    @State private var name = ""
    @State private var kind: CLIKind = .codex
    @State private var executable = "codex"
    @State private var arguments = ""
    @State private var archived = false
    @State private var version: String?
    @State private var failure: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preset == nil ? "Create Shared Agent Preset" : "Edit Shared Agent Preset").font(.title2)
            Form {
                TextField("Name", text: $name, prompt: Text(kind.displayName)).accessibilityIdentifier("base-agent.name")
                Picker("Agent", selection: $kind) {
                    Text("Claude Code").tag(CLIKind.claude)
                    Text("Codex").tag(CLIKind.codex)
                }.onChange(of: kind) { _, value in
                    if executable == "claude" || executable == "codex" { executable = value.rawValue }
                }
                HStack {
                    TextField("Executable", text: $executable).accessibilityIdentifier("base-agent.executable")
                    Button("Choose…") { if let path = FilePanels.executable() { executable = path } }
                }
                if preset != nil { Toggle("Archived", isOn: $archived) }
            }
            Text("Launch arguments").font(.headline)
            ArgumentEditor(text: $arguments).frame(height: 84).accessibilityIdentifier("base-agent.arguments")
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("Quote values containing spaces. Configuration directories are set on each team.").font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Shared Agent Preset") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(24).frame(width: 620).onAppear {
            name = preset?.name ?? ""; kind = preset?.kind ?? .codex; executable = preset?.executable ?? "codex"
            arguments = ArgumentText.format(preset?.arguments ?? []); archived = preset?.archived ?? false
            version = model.snapshot.store.baseAgentPresets.first { $0.value.id == preset?.id }?.version
        }
    }
    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                var value = preset ?? BaseAgentPreset(name: name, kind: kind, executable: executable)
                value.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.displayName : name
                value.kind = kind; value.executable = executable; value.archived = archived
                value.arguments = try ArgumentText.parse(arguments)
                try await model.save("saveBaseAgentPreset", value, version: version)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}

struct AddBaseAgentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let teamID: UUID
    let completion: (UUID) -> Void
    @State private var editing: AgentPreset?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add from Shared Presets").font(.title2)
            Text("Choose a preset to make an independent, editable copy.").foregroundStyle(.secondary)
            if model.snapshot.store.baseAgentPresets.allSatisfy({ $0.value.archived }) {
                Text("No active shared presets. Add one in Shared Agent Presets first.").foregroundStyle(.secondary)
            }
            List(model.snapshot.store.baseAgentPresets.map(\.value).filter { !$0.archived }.sorted { $0.name < $1.name }) { base in
                Button {
                    guard let team = model.presetSets.first(where: { $0.id == teamID }) else { return }
                    editing = base.agent(in: team, copy: true)
                } label: {
                    HStack { Text(base.name); Spacer(); Text(base.kind.displayName).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
            }.frame(height: 260)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 500)
            .sheet(item: $editing) { agent in
                PresetEditor(setID: teamID, preset: agent) { id in completion(id); dismiss() }
            }
    }
}
