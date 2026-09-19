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
                    Toggle(kind.displayName, isOn: Binding(get: { setup.draft.accountCounts[kind.rawValue] != nil }, set: {
                        setup.draft.accountCounts[kind.rawValue] = $0 ? .single : nil
                    })).font(.headline).accessibilityIdentifier("onboarding.agent.\(kind.rawValue)")
                    if setup.draft.accountCounts[kind.rawValue] != nil {
                        HStack {
                            TextField("Executable", text: Binding(get: { setup.executables[kind.rawValue] ?? "" }, set: { setup.executables[kind.rawValue] = $0 }))
                                .accessibilityIdentifier("onboarding.executable.\(kind.rawValue)")
                            Button("Choose…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
                                if panel.runModal() == .OK, let path = panel.url?.path { setup.executables[kind.rawValue] = path }
                            }
                        }
                        if setup.executables[kind.rawValue, default: ""].isEmpty || (setup.executables[kind.rawValue, default: ""].hasPrefix("/") && !FileManager.default.isExecutableFile(atPath: setup.executables[kind.rawValue, default: ""])) {
                            HStack {
                                Text("Not installed or not found.").foregroundStyle(.orange)
                                Link("Installation instructions", destination: URL(string: kind == .codex ? "https://developers.openai.com/codex/cli" : "https://code.claude.com/docs/en/setup")!)
                                Button("Recheck") { Task { await setup.perform {
                                    let previous = setup.inventory?.executables ?? [:]
                                    setup.inventory = try await setup.call("setupInventory").decode(SetupInventory.self)
                                    for candidate in CLIKind.allCases where candidate.isAgent {
                                        let key = candidate.rawValue
                                        if setup.executables[key] == previous[key] || setup.executables[key, default: ""].isEmpty {
                                            setup.executables[key] = setup.inventory?.executables[key]
                                        }
                                    }
                                } } }
                            }.font(.caption)
                        }
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
    }
}
