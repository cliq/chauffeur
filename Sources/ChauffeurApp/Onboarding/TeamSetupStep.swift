import SwiftUI
import ChauffeurCore

struct TeamSetupStep: View {
    @ObservedObject var setup: OnboardingModel
    var body: some View {
        Text("Name your teams").font(.headline)
        Text("A team groups agent settings for your projects. It doesn't create a provider account or subscription.").foregroundStyle(.secondary)
        ForEach($setup.draft.teams) { $team in
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Personal, Work, or client name", text: $team.name).accessibilityIdentifier("onboarding.teamName")
                        Button("Remove", role: .destructive) {
                            setup.draft.teams.removeAll { $0.id == team.id }
                            if setup.draft.defaultTeamID == team.id { setup.draft.defaultTeamID = setup.draft.teams.first?.id }
                        }.disabled(team.savedVersion != nil || team.agents.contains { $0.operationID != nil })
                    }
                    HStack {
                        ForEach(setup.selectedKinds, id: \.self) { kind in
                            Toggle(kind.displayName, isOn: Binding(get: { team.agents.contains { $0.kind == kind } }, set: { enabled in
                                if enabled { team.agents.append(setup.newPair(kind: kind, teamName: team.name)) }
                                else { team.agents.removeAll { $0.kind == kind } }
                            })).toggleStyle(.checkbox).disabled(team.savedVersion != nil || team.agents.contains { $0.operationID != nil })
                        }
                    }
                }.padding(6)
            }
        }
        HStack {
            Button("Add team") { setup.addTeam() }.accessibilityIdentifier("onboarding.addTeam")
            if !setup.draft.teams.contains(where: { $0.name == "Work" }) {
                Button("Add Work team") { setup.addTeam(name: "Work") }
            }
        }
    }
}
