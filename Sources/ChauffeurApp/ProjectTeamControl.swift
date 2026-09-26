import SwiftUI
import ChauffeurCore

struct ProjectTeamControl: View {
    @EnvironmentObject private var model: AppModel
    let project: Project
    let changeTeam: () -> Void
    @State private var showing = false
    @State private var editing: PresetSet?
    private var team: PresetSet? { model.presetSets.first { $0.id == project.presetSetID } }
    var body: some View {
        Button { showing.toggle() } label: {
            Text("Team: \(team?.name ?? "Unavailable")")
        }.accessibilityIdentifier("project.team")
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Team: \(team?.name ?? "Unavailable")").font(.headline)
                    if let team {
                        if team.archived { Text("This team is archived. Choose an active team to launch terminals.").foregroundStyle(.orange) }
                        ForEach(CLIKind.allCases.filter(\.isAgent), id: \.self) { kind in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.configurationFolderLabel).fontWeight(.medium)
                                Text(ShellAgentEnvironment.variableName(for: kind)!).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(team.configurationDirectory(for: kind)).textSelection(.enabled)
                                if (team.configurationDirectories?[kind.rawValue] ?? "").isEmpty { Text(kind == .opencode ? "Global configuration only" : "Agent default").font(.caption).foregroundStyle(.secondary) }
                                else if let note = kind.configurationFolderNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                                else if (try? Paths.directory(team.configurationDirectory(for: kind))) == nil {
                                    Text("Directory unavailable. Shells keep this value; agent launches require an accessible directory.").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        Text("Applies to new agent and shell terminals. Existing sessions keep their launch configuration.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Edit Team…") { showing = false; editing = team }
                    }
                    Button("Change Project Team…") { showing = false; changeTeam() }
                }.padding(20).frame(width: 380)
            }
            .sheet(item: $editing) { team in ProjectTeamSheet(teamID: team.id) { editing = nil } }
    }
}

/// The Teams settings detail for one team, so agents can be added and edited
/// without leaving the project.
private struct ProjectTeamSheet: View {
    @EnvironmentObject private var model: AppModel
    let teamID: UUID
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let team = model.presetSets.first(where: { $0.id == teamID }) {
                TeamDetailView(set: team, showsEditTeam: true)
            } else {
                ContentUnavailableView("Team unavailable", systemImage: "person.crop.rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 640, height: 600)
    }
}
