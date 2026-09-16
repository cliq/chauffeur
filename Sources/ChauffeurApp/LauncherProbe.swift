#if DEBUG
import AppKit
import ChauffeurCore

/// Native routing fixture. Enabled only with its own explicit data directory/socket.
@MainActor enum LauncherProbe {
    private static var started = false
    static func start(model: AppModel) {
        guard !started, let path = ProcessInfo.processInfo.environment["CHAUFFEUR_LAUNCHER_PROBE_DIR"],
              model.socketPath == URL(fileURLWithPath: path).appendingPathComponent("runtime/runtime.sock").path else { return }
        started = true
        Task {
            let root = URL(fileURLWithPath: path)
            while !Task.isCancelled {
                let commandURL = root.appendingPathComponent("launcher-command.json")
                if let data = try? Data(contentsOf: commandURL), let command = try? JSONCoding.decode(JSONValue.self, from: data) {
                    try? FileManager.default.removeItem(at: commandURL)
                    switch command["action"].string {
                    case "choose":
                        if let match = model.folderSelection?.matches.first(where: { $0.projectID.uuidString == command["projectID"].string }) { model.chooseProjectForFolder(match) }
                    case "clearError": model.error = nil
                    case "hideSidebar":
                        if let id = command["projectID"].string.flatMap(UUID.init(uuidString:)), let layout = NativeProbe.layouts[id] {
                            layout.state.sidebarVisible = false
                        }
                    case "quit": await model.finishPendingWindowWrites(); model.quit(); return
                    default: break
                    }
                }
                let visible = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("project-") == true }
                let result: JSONValue = .object([
                    "processID": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                    "online": .bool(model.online),
                    "projectCount": .number(Double(model.projects.count)),
                    "windows": .array(visible.map { .string($0.identifier!.rawValue) }),
                    "selectedFolders": .object(Dictionary(uniqueKeysWithValues: NativeProbe.layouts.map { ($0.key.uuidString, $0.value.selectedFolderID.map { .string($0.uuidString) } ?? .null) })),
                    "choices": .array((model.folderSelection?.matches ?? []).map { .string($0.projectID.uuidString) }),
                    "error": model.error.map(JSONValue.string) ?? .null,
                    "welcomeVisible": .bool(NSApp.windows.contains { $0.isVisible && $0.title == "Welcome to \(AppBuild.current.displayName)" })
                ])
                try? JSONCoding.encode(result).write(to: root.appendingPathComponent("launcher-state.json"), options: .atomic)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
#endif
