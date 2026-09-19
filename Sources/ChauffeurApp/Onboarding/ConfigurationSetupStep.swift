import SwiftUI
import ChauffeurCore

struct ConfigurationSetupStep: View {
    @ObservedObject var setup: OnboardingModel
    var body: some View {
        Text("Connect accounts and settings").font(.headline)
        Text("Already have different configuration folders? Choose them below. Otherwise, create a separate configuration and we'll help you copy settings and sign in.").foregroundStyle(.secondary)
        ForEach($setup.draft.teams) { $team in
            ForEach($team.agents) { $pair in
                GroupBox("\(team.name) · \(pair.kind.displayName)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Configuration", selection: $pair.choice) {
                            Text("Use my current configuration").tag(ConfigurationChoice.current)
                            Text("Choose an existing folder").tag(ConfigurationChoice.existing)
                            Text("Create a separate configuration").tag(ConfigurationChoice.create)
                        }.accessibilityIdentifier("onboarding.configuration.\(pair.id)")
                            .disabled(pair.operationID != nil)
                            .onChange(of: pair.choice) { _, choice in
                                switch choice {
                                case .current: pair.destinationPath = setup.currentPath(pair.kind)
                                case .create: pair.destinationPath = setup.suggestedDestination(kind: pair.kind, name: team.name)
                                case .existing: break
                                }
                                pair.previewID = nil; setup.previews[pair.id] = nil; pair.auth = SetupAuthStatus()
                            }
                        HStack {
                            TextField("Configuration folder", text: $pair.destinationPath)
                                .disabled(pair.choice == .current || pair.operationID != nil)
                                .accessibilityIdentifier("onboarding.destination.\(pair.id)")
                            if pair.choice == .existing {
                                Button("Choose…") { if let path = FilePanels.directory(title: "Choose configuration folder", showsHiddenFiles: true) { pair.destinationPath = path } }
                                    .disabled(pair.operationID != nil)
                            }
                        }
                        if pair.choice == .existing, pair.operationID == nil {
                            Menu("Detected and shared configurations") {
                                ForEach(setup.inventory?.configurations.filter { $0.kind == pair.kind } ?? [], id: \.path) { candidate in
                                    Button(candidate.path) { pair.destinationPath = candidate.path }
                                }
                                ForEach(setup.draft.teams.filter { $0.id != team.id }) { other in
                                    if let shared = other.agents.first(where: { $0.kind == pair.kind }) {
                                        Button("Use \(other.name)'s configuration") { pair.destinationPath = shared.destinationPath }
                                    }
                                }
                            }
                        }
                        let sharing = setup.draft.teams.filter { other in other.id != team.id && other.agents.contains { $0.kind == pair.kind && Paths.canonical($0.destinationPath) == Paths.canonical(pair.destinationPath) } }.map(\.name)
                        if !sharing.isEmpty {
                            Label("Shared with \(sharing.joined(separator: ", ")). Login and settings changes apply to these teams too.", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                        }
                        if pair.operationID != nil { Text("Configuration saved. Its folder stays in place if you rename the team.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
