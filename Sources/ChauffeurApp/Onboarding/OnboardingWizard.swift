import SwiftUI
import ChauffeurCore

struct OnboardingWizard: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var setup = OnboardingModel()
    @State private var confirmingDiscard = false
    let onFinished: (UUID?) -> Void
    private let steps: [SetupStep] = [.agents, .teams, .configurations, .copy, .login, .summary]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up your teams").font(.title2.bold())
                    Text("Choose the accounts and settings your projects use.").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\((steps.firstIndex(of: setup.draft.step) ?? 0) + 1) of \(steps.count)").foregroundStyle(.secondary)
            }
            Divider()
            if !setup.loaded {
                ProgressView("Finding your agents and configurations…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch setup.draft.step {
                        case .agents: AgentSetupStep(setup: setup)
                        case .teams: TeamSetupStep(setup: setup)
                        case .configurations: ConfigurationSetupStep(setup: setup)
                        case .copy: CopySettingsStep(setup: setup)
                        case .login: LoginSetupStep(setup: setup)
                        case .summary: SetupSummaryStep(setup: setup)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
                }.disabled(setup.busy)
            }
            if let error = setup.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Reload setup") { Task { await setup.perform { try await setup.reload() } } }
                }.font(.callout).foregroundStyle(.red).accessibilityIdentifier("onboarding.error")
            }
            Divider()
            HStack {
                Button("Discard Setup…", role: .destructive) { confirmingDiscard = true }.accessibilityIdentifier("onboarding.discard")
                Button("Save and Finish Later") {
                    Task { if await setup.finishLater() { dismiss() } }
                }.accessibilityIdentifier("onboarding.finishLater")
                Spacer()
                if setup.busy { ProgressView().controlSize(.small) }
                if setup.draft.step != .agents {
                    Button("Back") { setup.back() }.accessibilityIdentifier("onboarding.back")
                }
                if setup.draft.step == .summary {
                    Button("Open your first project") {
                        Task { if let team = await setup.finish() { onFinished(team); dismiss() } }
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding.openProject")
                    Button("Finish") {
                        Task { if await setup.finish() != nil { onFinished(nil); dismiss() } }
                    }.accessibilityIdentifier("onboarding.finish")
                } else {
                    Button(continueTitle) { Task { await setup.next() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).accessibilityIdentifier("onboarding.continue")
                }
            }.disabled(setup.busy || !setup.loaded)
        }.padding(24).frame(width: 780, height: 650)
            .interactiveDismissDisabled()
            .alert("Discard unfinished setup?", isPresented: $confirmingDiscard) {
                Button("Cancel", role: .cancel) {}
                Button("Discard Setup", role: .destructive) { Task { if await setup.discard() { dismiss() } } }
            } message: {
                Text("Draft choices and unfinished copy staging will be removed. Created configuration folders and saved teams will be kept. Any active setup login will stop.")
            }
            .task { await setup.load(app: app) }
            .onChange(of: setup.draft) { _, _ in setup.scheduleSave() }
            .onDisappear { setup.stopObserving() }
    }

    private var continueTitle: String {
        if setup.draft.step == .copy { return "Create configurations" }
        if setup.draft.step == .login && setup.pairs.contains(where: { $0.auth.phase != .connected }) { return "Sign in later" }
        return "Continue"
    }
}

extension CopyCategory {
    var setupTitle: String {
        switch self {
        case .preferences: "Preferences"
        case .instructions: "Instructions"
        case .reusable: "Skills, prompts, rules, and agent definitions"
        case .plugins: "Plugins"
        case .connections: "MCP connections"
        case .hooks: "Hooks"
        case .history: "Project history and conversations"
        }
    }
}

extension SetupAuthStatus {
    var setupLabel: String {
        switch phase {
        case .notChecked: "Not checked"
        case .signingIn: "Signing in…"
        case .verifying: "Verifying…"
        case .connected: "Connected"
        case .signInRequired: "Sign-in required"
        case .unableToVerify: "Unable to verify"
        case .failed: "Sign-in failed"
        }
    }
}
