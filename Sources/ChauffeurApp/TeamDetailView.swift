import SwiftUI
import ChauffeurCore

/// Directories and agents of one team, shared by the Teams settings pane and
/// the project toolbar's Edit Team sheet. Owns the sheets for editing the
/// team's agents so both places can add and customize them.
struct TeamDetailView: View {
    @EnvironmentObject private var model: AppModel
    let set: PresetSet
    /// Shows an Edit Team… button in the header, for hosts without a team list.
    var showsEditTeam = false
    @State private var editedSet: PresetSet?
    @State private var newPreset = false
    @State private var editedBase: BaseAgentPreset?
    @State private var editedPreset: AgentPreset?
    @State private var skillPreset: AgentPreset?
    @State private var revealedPresetID: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(set.name).font(.title2); Spacer(); Text("Revision \(set.revision)").foregroundStyle(.secondary)
                if showsEditTeam { Button("Edit Team…") { editedSet = set }.disabled(!model.online).accessibilityIdentifier("team-detail.edit") }
            }
            Text(set.agentSelection == .allBase ? "Uses all agent presets. Changes to agent presets apply to new launches." : "Custom presets are independent copies. Team directories apply to every agent.").font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(CLIKind.allCases.filter(\.isAgent), id: \.self) { kind in
                    let variable = ShellAgentEnvironment.variableName(for: kind)!
                    GridRow {
                        Text(kind.configurationFolderLabel).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(set.configurationDirectory(for: kind)).font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .help("\(variable)=\(set.configurationDirectory(for: kind))")
                }
            }
            AgentPresetList(set: set, revealedPresetID: $revealedPresetID, edit: { agent in
                if set.agentSelection == .allBase { editedBase = model.snapshot.store.baseAgentPresets.first { $0.value.id == agent.id }?.value }
                else { editedPreset = agent }
            }, showSkill: { skillPreset = $0 })
            if set.agentSelection != .allBase { Button("Add Agent…") { newPreset = true }.disabled(set.archived) }
        }
        .sheet(item: $editedSet) { set in PresetSetEditor(presetSet: set) { _ in editedSet = nil } }
        .sheet(isPresented: $newPreset) { AddBaseAgentView(teamID: set.id) { revealedPresetID = $0 } }
        .sheet(item: $editedBase) { base in BaseAgentEditor(preset: base) }
        .sheet(item: $editedPreset) { preset in PresetEditor(setID: preset.setID, preset: preset) { revealedPresetID = $0 } }
        .sheet(item: $skillPreset) { preset in CoordinationSkillView(preset: preset) }
    }
}
