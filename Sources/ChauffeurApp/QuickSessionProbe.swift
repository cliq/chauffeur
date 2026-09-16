#if DEBUG
import AppKit
import ChauffeurCore

/// Exercises the actual sheet and operation against an explicitly isolated runtime.
@MainActor enum QuickSessionProbe {
    static var openSheet: [UUID: (UUID) -> Void] = [:]
    static var openWorktrees: [UUID: (UUID) -> Void] = [:]
    static var sheetCommand: ((JSONValue) -> Void)?
    static var sheetState: (() -> JSONValue)?
    static var sheetID: UUID?
    private(set) static var enabled = false
    static func start(model: AppModel) {
        guard !enabled, let path = ProcessInfo.processInfo.environment["CHAUFFEUR_QUICK_SESSION_PROBE_DIR"],
              model.socketPath == URL(fileURLWithPath: path).appendingPathComponent("runtime/runtime.sock").path else { return }
        enabled = true
        Task {
            let root = URL(fileURLWithPath: path)
            var commandID: JSONValue = .null
            while !Task.isCancelled {
                let commandURL = root.appendingPathComponent("quick-command.json")
                if let data = try? Data(contentsOf: commandURL), let command = try? JSONCoding.decode(JSONValue.self, from: data) {
                    try? FileManager.default.removeItem(at: commandURL)
                    commandID = command["id"]
                    if command["action"].string == "open", let project = command["projectID"].string.flatMap(UUID.init(uuidString:)), let folder = command["folderID"].string.flatMap(UUID.init(uuidString:)) {
                        openSheet[project]?(folder)
                    } else if command["action"].string == "openWorktrees", let project = command["projectID"].string.flatMap(UUID.init(uuidString:)), let folder = command["folderID"].string.flatMap(UUID.init(uuidString:)) {
                        openWorktrees[project]?(folder)
                    } else if command["action"].string == "quit" { model.quit(); return }
                    else if command["action"].string == "refresh" { try? await model.refresh() }
                    else { sheetCommand?(command) }
                }
                let sheet = NativeProbe.layouts.values.compactMap { $0.window?.attachedSheet }.first
                let result: JSONValue = .object([
                    "processID": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                    "online": .bool(model.online),
                    "commandID": commandID,
                    "ready": .bool(!openSheet.isEmpty),
                    "sheet": sheetState?() ?? .null,
                    "sheetWindow": sheet.map { .number(Double($0.windowNumber)) } ?? .null,
                    "selectedSession": NativeProbe.layouts.values.first?.state.selectedSessionID.map { .string($0.uuidString) } ?? .null,
                    "error": model.error.map(JSONValue.string) ?? .null
                ])
                try? JSONCoding.encode(result).write(to: root.appendingPathComponent("quick-state.json"), options: .atomic)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
#endif
