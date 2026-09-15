import SwiftUI
import AppKit
import ChauffeurCore

@main struct ChauffeurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Welcome to Chauffeur", id: "welcome") {
            WelcomeView().modifier(AppAlerts()).environmentObject(model)
        }
        .defaultSize(width: 820, height: 500)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        WindowGroup("Project", id: "project", for: UUID.self) { $projectID in
            if let projectID {
                ProjectWindow(projectID: projectID).modifier(AppAlerts()).environmentObject(model)
            }
        }
        .defaultSize(width: 1240, height: 820)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project Window…") { openWindow(id: "welcome") }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("New Session…") { NotificationCenter.default.post(name: .chauffeurCommand, object: "new-session") }.keyboardShortcut("n")
            }
            CommandMenu("Session") {
                Button("Next Session") { command("next") }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Session") { command("previous") }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Search Sessions…") { command("search-sessions") }.keyboardShortcut("k")
                Button("Split / Unsplit Terminal") { command("split") }.keyboardShortcut("d")
                Button("Find in Terminal…") { command("find") }.keyboardShortcut("f")
                Button("Next Attention Item") { command("attention") }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Welcome to Chauffeur") { openWindow(id: "welcome") }.keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandGroup(before: .appTermination) {
                Button("Stop All Sessions and Quit…") { model.stopAllPresented = true }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Chauffeur") { model.quit() }.keyboardShortcut("q")
            }
            CommandGroup(replacing: .help) {
                Button("Chauffeur Help") { openWindow(id: "help") }
            }
        }
        Settings { SettingsView().modifier(AppAlerts()).environmentObject(model) }
        Window("Chauffeur Help", id: "help") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your agents keep running").font(.title)
                Text("Closing a terminal tab, project window, or quitting Chauffeur detaches the view. Reopen a project to reconnect to the same live terminal.")
                Text("Use Stop session to end an execution. Interrupt sends Control-C. Resume conversation starts a new process using its recorded native conversation ID and original profile.")
                Text("Messages stay in an agent's inbox until it reads them through Chauffeur's MCP tools. If an idle agent needs to read its inbox, prompt it explicitly in its terminal.")
                Text("A worktree isolates one repository. Additional repository paths are shown when launching and use their selected existing checkouts.")
                Text("Profiles reference existing CLI configuration directories. Chauffeur does not create accounts or manage sign-in.")
            }.padding(30).frame(width: 580)
        }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
    }
    private func command(_ name: String) { NotificationCenter.default.post(name: .chauffeurCommand, object: name) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    func applicationDidFinishLaunching(_ notification: Notification) { model.start() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.isTerminating = true
        return .terminateNow
    }
}
extension Notification.Name { static let chauffeurCommand = Notification.Name("ChauffeurCommand") }

struct AppAlerts: ViewModifier {
    @EnvironmentObject private var model: AppModel
    func body(content: Content) -> some View {
        content.alert("Chauffeur", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.stopAllPresented) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Stop all sessions and quit?").font(.title2)
                Text("These executions will receive a graceful stop request:")
                List(model.snapshot.sessions.filter { $0.state.isLive }) { session in
                    Text("\(model.project(session.projectID)?.name ?? "Project unavailable") · \(session.title)")
                }.frame(height: 220)
                HStack {
                    Button("Cancel") { model.stopAllPresented = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Stop All and Quit", role: .destructive) { model.stopAllPresented = false; model.stopAllAndQuit() }
                }
            }.padding(24).frame(width: 530)
        }
    }
}
