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
                                Text(ShellAgentEnvironment.variableName(for: kind)!).font(.caption).foregroundStyle(.secondary)
                                Text(team.configurationDirectory(for: kind)).textSelection(.enabled)
                                if (team.configurationDirectories?[kind.rawValue] ?? "").isEmpty { Text("Agent default").font(.caption).foregroundStyle(.secondary) }
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
            .sheet(item: $editing) { team in PresetSetEditor(presetSet: team) { _ in editing = nil } }
    }
}
