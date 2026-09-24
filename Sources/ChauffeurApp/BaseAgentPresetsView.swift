import SwiftUI
import ChauffeurCore

struct BaseAgentPresetsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var editing: BaseAgentPreset?
    private var presets: [BaseAgentPreset] {
        model.snapshot.store.baseAgentPresets.map(\.value).sorted { $0.name < $1.name }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agent Presets").font(.title2)
            Text("Define launch commands once. Teams using all agent presets inherit changes; custom copies remain independent.")
                .foregroundStyle(.secondary)
            List(presets) { preset in
                BaseAgentPresetRow(preset: preset) { editing = preset }
            }
            Button("Add Agent Preset…") { adding = true }.disabled(!model.online)
        }.padding(20)
            .sheet(isPresented: $adding) { BaseAgentEditor() }
            .sheet(item: $editing) { BaseAgentEditor(preset: $0) }
    }
}

private struct BaseAgentPresetRow: View {
    let preset: BaseAgentPreset
    let edit: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Text(preset.name).font(.headline)
                    AgentKindBadge(kind: preset.kind)
                }
                Text("\(preset.kind.displayName) · \(command)").font(.caption).textSelection(.enabled)
            }
            Spacer()
            if preset.archived { Text("Archived").foregroundStyle(.secondary) }
            Button("Edit…", action: edit)
        }.padding(.vertical, 6)
    }

    private var command: String {
        let arguments = preset.rawArguments ?? ArgumentText.format(preset.arguments)
        return arguments.isEmpty ? preset.executable : "\(preset.executable) \(arguments)"
    }
}

struct BaseAgentEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var preset: BaseAgentPreset?
    @State private var name = ""
    @State private var kind: CLIKind = .codex
    @State private var executable = "codex"
    @State private var usesSpecificDirectory = false
    @State private var configurationDirectory = ""
    @State private var arguments = ""
    @State private var archived = false
    @State private var version: String?
    @State private var failure: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(preset == nil ? "Create Agent Preset" : "Edit Agent Preset").font(.title2)
            Form {
                TextField("Name", text: $name, prompt: Text(kind.displayName)).accessibilityIdentifier("base-agent.name")
                Picker("Agent", selection: $kind) {
                    ForEach(AgentProviders.all, id: \.kind) { Text($0.displayName).tag($0.kind) }
                }.onChange(of: kind) { _, value in
                    if AgentProviders.all.contains(where: { $0.kind.rawValue == executable }) { executable = value.rawValue }
                }
                HStack {
                    TextField("Executable", text: $executable).accessibilityIdentifier("base-agent.executable")
                    Button("Choose…") { if let path = FilePanels.executable() { executable = path } }
                }
                Picker("Configuration", selection: $usesSpecificDirectory) {
                    Text("Use team configuration").tag(false)
                    Text("Use a specific directory").tag(true)
                }.accessibilityIdentifier("base-agent.configuration")
                if usesSpecificDirectory {
                    HStack {
                        TextField("Directory", text: $configurationDirectory)
                            .accessibilityIdentifier("base-agent.configuration-directory")
                        Button("Choose…") {
                            if let path = FilePanels.directory(title: "Choose configuration directory", startingAt: FileManager.default.homeDirectoryForCurrentUser, showsHiddenFiles: true) {
                                configurationDirectory = path
                            }
                        }
                    }
                    Text("Uses this directory in every team that includes this preset.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if preset != nil { Toggle("Archived", isOn: $archived) }
            }
            PresetLaunchOptionsEditor(rawArguments: $arguments, kind: kind)
            Text("Launch arguments").font(.headline)
            ArgumentEditor(text: $arguments).frame(height: 84).accessibilityIdentifier("base-agent.arguments")
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("Quote values containing spaces.").font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Agent Preset") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(24).frame(width: 620).onAppear {
            name = preset?.name ?? ""; kind = preset?.kind ?? .codex; executable = preset?.executable ?? "codex"
            arguments = preset.map { $0.rawArguments ?? ArgumentText.format($0.arguments) } ?? ""; archived = preset?.archived ?? false
            usesSpecificDirectory = preset?.configurationDirectoryOverride != nil
            configurationDirectory = preset?.configurationDirectoryOverride ?? ""
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
                value.configurationDirectoryOverride = usesSpecificDirectory
                    ? (configurationDirectory.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath : nil
                value.rawArguments = arguments
                if let parsed = try? ArgumentText.parse(arguments) { value.arguments = parsed }
                try value.validate()
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
            Text("Pick Agent Preset").font(.title2)
            Text("Choose a preset to make an independent, editable copy.").foregroundStyle(.secondary)
            if model.snapshot.store.baseAgentPresets.allSatisfy({ $0.value.archived }) {
                Text("No active agent presets. Create one in Agent Presets first.").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.snapshot.store.baseAgentPresets.map(\.value).filter { !$0.archived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { base in
                        AgentPresetCard(preset: base) {
                            guard let team = model.presetSets.first(where: { $0.id == teamID }) else { return }
                            editing = base.agent(in: team, copy: true)
                        }
                    }
                }.padding(2)
            }.frame(height: 260)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        }.frame(width: 452, alignment: .leading).padding(24)
            .sheet(item: $editing) { agent in
                PresetEditor(setID: teamID, preset: agent) { id in completion(id); dismiss() }
            }
    }
}

struct AgentKindBadge: View {
    let kind: CLIKind

    var body: some View {
        AgentBadge(label: kind.displayName, color: AgentBadge.color(named: kind.provider?.badgeColorName))
    }
}

private struct AgentPresetCard: View {
    let preset: BaseAgentPreset
    let pick: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preset.name).font(.headline)
                    Text(command)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                AgentKindBadge(kind: preset.kind)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .background(hovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hovered ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1))
        .onHover { hovered = $0 }
        .accessibilityLabel(preset.name)
        .accessibilityHint("Customize a copy of this \(preset.kind.displayName) preset for the team")
        .accessibilityIdentifier("agent-preset.pick-\(preset.id.uuidString)")
    }
    private var command: String {
        let arguments = preset.rawArguments ?? ArgumentText.format(preset.arguments)
        return arguments.isEmpty ? preset.executable : "\(preset.executable) \(arguments)"
    }
}
