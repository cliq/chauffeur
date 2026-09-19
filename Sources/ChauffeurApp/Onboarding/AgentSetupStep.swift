import SwiftUI
import ChauffeurCore

struct AgentSetupStep: View {
    @ObservedObject var setup: OnboardingModel
    var body: some View {
        Text("Which agents do you use?").font(.headline)
        Text("Teams let you choose which account and settings to use for each project. You can separate Personal, Work, or client settings even with one account.")
        ForEach(CLIKind.allCases.filter(\.isAgent), id: \.self) { kind in
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    let detected = setup.inventory?.executables[kind.rawValue] != nil
                    HStack {
                        Toggle(kind.displayName, isOn: Binding(get: {
                            detected && setup.draft.accountCounts[kind.rawValue] != nil
                        }, set: {
                            setup.draft.accountCounts[kind.rawValue] = $0 ? .single : nil
                        }))
                        .font(.headline)
                        .disabled(!detected)
                        .accessibilityIdentifier("onboarding.agent.\(kind.rawValue)")
                        Spacer()
                        if detected {
                            Label("Detected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityIdentifier("onboarding.detected.\(kind.rawValue)")
                        } else {
                            Text("Not detected").foregroundStyle(.secondary)
                            Link("Install \(kind.displayName)", destination: URL(string: kind == .codex
                                ? "https://developers.openai.com/codex/cli"
                                : "https://code.claude.com/docs/en/setup")!)
                                .accessibilityIdentifier("onboarding.install.\(kind.rawValue)")
                        }
                    }
                    if detected && setup.draft.accountCounts[kind.rawValue] != nil {
                        Picker("Accounts", selection: Binding(get: { setup.draft.accountCounts[kind.rawValue] ?? .single }, set: { setup.draft.accountCounts[kind.rawValue] = $0 })) {
                            Text("One account").tag(AccountCount.single)
                            Text("Multiple accounts").tag(AccountCount.multiple)
                            Text("Not sure").tag(AccountCount.unsure)
                        }.pickerStyle(.segmented).accessibilityIdentifier("onboarding.accounts.\(kind.rawValue)")
                        if setup.draft.accountCounts[kind.rawValue] == .unsure {
                            Text("For example: use your personal subscription for side projects and your company account for work. Each team can use its own login, or share the same settings and account.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        Button("Recheck installed agents") {
            Task { await setup.perform { try await setup.refreshAgentDetection() } }
        }.accessibilityIdentifier("onboarding.recheckAgents")
    }
}
