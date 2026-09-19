import SwiftUI
import ChauffeurCore

struct LoginSetupStep: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var setup: OnboardingModel
    var body: some View {
        Text("Sign in to each account").font(.headline)
        Text("Check the browser account before completing sign-in. You can sign in now or continue and sign in later. New configurations don't copy the source account's login.").foregroundStyle(.secondary)
        ForEach(setup.draft.teams) { team in
            ForEach(team.agents) { pair in
                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("\(team.name) · \(pair.kind.displayName)").font(.headline)
                            Spacer()
                            Label(pair.auth.setupLabel, systemImage: pair.auth.phase == .connected ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                                .foregroundStyle(pair.auth.phase == .connected ? Color.green : Color.secondary)
                        }
                        Text(pair.destinationPath).font(.caption).textSelection(.enabled)
                        if let email = pair.auth.email { Text(email) }
                        if let org = pair.auth.organization { Text(org).font(.caption) }
                        if let method = pair.auth.method { Text("Authentication: \(method)").font(.caption) }
                        if pair.auth.phase == .connected && pair.auth.email == nil { Text("Signed in according to the CLI. Account identity isn't available.").font(.caption).foregroundStyle(.secondary) }
                        if let message = pair.auth.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Button(pair.auth.phase == .connected ? "Not the right account? Sign in again" : "Sign in") { Task { await setup.signIn(pair.id) } }
                                .disabled(setup.pairs.contains { [.signingIn, .verifying].contains($0.auth.phase) })
                                .accessibilityIdentifier("onboarding.signIn.\(pair.kind.rawValue)")
                            Button("Recheck") { Task { await setup.verify(pair.id) } }.disabled([.signingIn, .verifying].contains(pair.auth.phase))
                            if setup.loginPairID == pair.id, [.signingIn, .verifying].contains(pair.auth.phase) {
                                Button("Cancel login") { Task { await setup.cancelLogin() } }
                            }
                        }
                        if setup.loginPairID == pair.id, let login = setup.login {
                            SetupTerminalView(app: app, handle: login).frame(height: 220).id(login.operationID)
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
