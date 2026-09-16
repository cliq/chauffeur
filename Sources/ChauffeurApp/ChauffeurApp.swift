import SwiftUI
import AppKit
import ChauffeurCore

@main struct ChauffeurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Welcome to \(AppBuild.current.displayName)", id: "welcome") {
            WelcomeView().modifier(AppWindowSetup()).environmentObject(model)
        }
        .defaultSize(width: 820, height: 500)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        WindowGroup("Project", id: "project", for: UUID.self) { $projectID in
            if let projectID {
                ProjectWindow(projectID: projectID).modifier(AppWindowSetup()).environmentObject(model)
            }
        }
        .defaultSize(width: 1240, height: 820)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { openWindow(id: "welcome") }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("New Tab…") { command("new-tab") }.keyboardShortcut("t")
                Button("New Session…") { NotificationCenter.default.post(name: .chauffeurCommand, object: "new-session") }.keyboardShortcut("n")
            }
            CommandMenu("Session") {
                Button("Next Session") { command("next") }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Session") { command("previous") }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Sidebar Item") { command("sidebar-next") }.keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Sidebar Item") { command("sidebar-previous") }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Search Sessions…") { command("search-sessions") }.keyboardShortcut("k")
                Button("Find in Terminal…") { command("find") }.keyboardShortcut("f")
                Button("Next Attention Item") { command("attention") }.keyboardShortcut("a", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Button("Welcome to Chauffeur") { openWindow(id: "welcome") }.keyboardShortcut("0", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appTermination) {
                Button("Stop All Sessions and Quit…") { model.confirmStopAllAndQuit() }
                    .disabled(model.stopAllPresented || model.isStoppingAll)
                Divider()
                Button("Quit Chauffeur") { model.quit() }.keyboardShortcut("q")
            }
            CommandGroup(replacing: .help) {
                Button("Chauffeur Help") { openWindow(id: "help") }
            }
        }
        Settings { SettingsView().modifier(AppWindowSetup()).environmentObject(model) }
            .defaultSize(width: 830, height: 550)
            .windowResizability(.contentMinSize)
        Window("Chauffeur Help", id: "help") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your agents keep running").font(.title)
                Text("Closing a project window or quitting Chauffeur detaches the view. Reopen a project to reconnect to the same live terminal.")
                Text("Use Stop session to end an execution. Interrupt sends Control-C. Resume conversation starts a new process using its recorded native conversation ID and original profile.")
                Text("Messages stay in an agent's inbox until it reads them through Chauffeur's MCP tools. If an idle agent needs to read its inbox, prompt it explicitly in its terminal.")
                Text("A worktree isolates one repository. Select a worktree in the sidebar to see its sessions, launch an agent there, or open a shell. Additional repository paths are shown when launching and use their selected existing checkouts.")
                Text("Profiles reference existing CLI configuration directories. Chauffeur does not create accounts or manage sign-in.")
            }.padding(30).frame(width: 580)
        }.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
    }
    private func command(_ name: String) { NotificationCenter.default.post(name: .chauffeurCommand, object: name) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var errors: AppErrorPresenter?
    private var preparingToQuit = false
    private var quitConfirmation: QuitConfirmation?
    func applicationDidFinishLaunching(_ notification: Notification) {
        errors = AppErrorPresenter(model: model)
        model.start()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { model.openSessionURL(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.isTerminating { return .terminateNow }
        guard !preparingToQuit else { return .terminateCancel }
        preparingToQuit = true
        // Return to the normal run loop before presenting UI or awaiting work.
        // AppKit's terminateLater loop can starve main-actor tasks.
        Task {
            let active = model.snapshot.sessions.filter { $0.state.isLive }
            guard !active.isEmpty else { await finishQuitting(sender); return }
            let prompt = QuitConfirmation()
            quitConfirmation = prompt
            prompt.show(sessionCount: active.count) { [weak self] choice in
                guard let self else { return }
                self.quitConfirmation = nil
                switch choice {
                case .keepRunning:
                    Task { await self.finishQuitting(sender) }
                case .review:
                    self.preparingToQuit = false
                    // Re-read the snapshot: a session may finish while the prompt is open.
                    let available = self.model.snapshot.sessions.filter { $0.state.isLive && self.model.project($0.projectID) != nil }
                    if let session = available.first(where: \.needsAttention) ?? available.first {
                        self.model.openSessionURL(SessionRoute(projectID: session.projectID, sessionID: session.id).url)
                    } else {
                        self.model.openWelcomeWindow?()
                    }
                case .cancel:
                    self.preparingToQuit = false
                }
            }
        }
        return .terminateCancel
    }
    private func finishQuitting(_ sender: NSApplication) async {
        await model.finishPendingWindowWrites()
        model.isTerminating = true
        sender.terminate(nil)
    }
}
extension Notification.Name { static let chauffeurCommand = Notification.Name("ChauffeurCommand") }

struct AppWindowSetup: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.tint(Color("AccentColor")).accentColor(Color("AccentColor")).onAppear {
            model.openProjectWindow = { id in openWindow(id: "project", value: id) }
            model.openWelcomeWindow = { openWindow(id: "welcome") }
            model.processPendingRoute()
        }
    }
}
