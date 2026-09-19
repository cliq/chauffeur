import SwiftUI
import ChauffeurCore

struct SetupSummaryStep: View {
    @ObservedObject var setup: OnboardingModel
    var body: some View {
        Text(setup.pairs.allSatisfy { $0.auth.phase == .connected } ? "Your teams are ready" : "Your team setup can be saved").font(.headline)
        if setup.pairs.contains(where: { $0.auth.phase != .connected }) {
            Text("Some agents still need sign-in or verification. You can resume setup later and use the ready configurations now.").foregroundStyle(.secondary)
        }
        Picker("Default team for new projects", selection: $setup.draft.defaultTeamID) {
            ForEach(setup.draft.teams) { team in Text(team.name).tag(Optional(team.id)) }
        }.accessibilityIdentifier("onboarding.defaultTeam")
        ForEach(setup.draft.teams) { team in
            GroupBox(team.name) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(team.agents) { pair in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack { Text(pair.kind.displayName).bold(); Spacer(); Text(pair.auth.setupLabel) }
                            Text(pair.destinationPath).font(.caption).textSelection(.enabled)
                            let sharing = setup.draft.teams.filter { other in other.id != team.id && other.agents.contains { $0.kind == pair.kind && Paths.canonical($0.destinationPath) == Paths.canonical(pair.destinationPath) } }.map(\.name)
                            if !sharing.isEmpty { Text("Shared with \(sharing.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
