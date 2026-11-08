import SwiftUI
import ChauffeurRemoteClient
import ChauffeurRemoteProtocol

@main
struct ChauffeurMobileApp: App {
    @State private var model = Self.makeModel()
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

extension ChauffeurMobileApp {
    static func makeModel() -> MobileAppModel {
        #if DEBUG
        // Opens on the preview inventory, for checking layouts on a simulator without
        // pairing; `--preview-location` continues to the new-session project step.
        if CommandLine.arguments.contains("--preview-fixture") {
            let model = MobileAppModel.preview()
            if CommandLine.arguments.contains("--preview-location") { model.path.append(.newSession) }
            return model
        }
        #endif
        return MobileAppModel(makeTerminalAdapter: MobileAppModel.defaultTerminalAdapterFactory())
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
                    case .documents(let sessionID):
                        SessionDocumentsView(model: model, sessionID: sessionID)
                    case .document(let sessionID, let path):
                        if DocumentKind(path: path) == .image {
                            ImageDocumentView(model: model, sessionID: sessionID, path: path)
                        } else {
                            DocumentReaderView(model: model, sessionID: sessionID, path: path)
                        }
                    case .newSession:
                        ProjectPickerView(model: model)
                    case .repository(let projectID):
                        RepositoryPickerView(model: model, projectID: projectID)
                    case .checkout(let projectID, let folderID):
                        CheckoutPickerView(model: model, projectID: projectID, folderID: folderID)
                    case .newWorktree(let projectID, let folderID, let baseRef):
                        NewWorktreeView(model: model, projectID: projectID, folderID: folderID, initialBaseRef: baseRef)
                    case .launch(let location, let prefill):
                        LaunchView(model: model, location: location, prefill: prefill)
                    }
                }
        }
        // Session links (`chauffeur://session/<project>/<session>`) from other apps.
        .onOpenURL { model.openSessionURL($0) }
    }
}

#Preview("Connected") {
    RootView(model: .preview())
}

#Preview("First launch") {
    RootView(model: MobileAppModel(
        credentials: InMemoryCredentialStore(),
        makeJournal: { _ in InMemoryOperationJournal() },
        defaults: nil,
        makeTerminalAdapter: MobileAppModel.defaultTerminalAdapterFactory(arguments: ["--fake-terminal"])
    ))
}
