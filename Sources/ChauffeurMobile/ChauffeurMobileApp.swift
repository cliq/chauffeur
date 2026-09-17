import SwiftUI
// Linked for the upcoming networking layer; proves the portable products build for iOS.
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

@main
struct ChauffeurMobileApp: App {
    @State private var model = MobileAppModel(makeTerminalAdapter: MobileAppModel.defaultTerminalAdapterFactory())

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
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
    RootView(model: MobileAppModel(makeTerminalAdapter: MobileAppModel.defaultTerminalAdapterFactory(arguments: ["--fake-terminal"])))
}
