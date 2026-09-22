import SwiftUI
import ChauffeurRemoteClient

@main
struct ChauffeurMobileApp: App {
    @State private var model = MobileAppModel(makeTerminalAdapter: MobileAppModel.defaultTerminalAdapterFactory())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.handleBackground()
            case .active:
                Task { await model.handleForeground() }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}

struct RootView: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        NavigationStack(path: $model.path) {
            ConnectView(model: model)
                .navigationDestination(for: MobileRoute.self) { route in
                    switch route {
                    case .sessions:
                        SessionsView(model: model)
                    case .terminal:
                        SessionTerminalView(model: model)
                    case .progress(let sessionID):
                        SessionProgressView(model: model, sessionID: sessionID)
                    case .location(let projectID):
                        LocationView(model: model, preselectedProjectID: projectID)
                    case .launch(let location):
                        LaunchView(model: model, location: location)
                    }
                }
        }
    }
}

#Preview("Connected") {
    RootView(model: .preview())
}

#Preview("First launch") {
    RootView(model: MobileAppModel(
        credentials: InMemoryCredentialStore(),
        journal: InMemoryOperationJournal(),
        makeTerminalAdapter: MobileAppModel.defaultTerminalAdapterFactory(arguments: ["--fake-terminal"])
    ))
}
