#if DEBUG
import AppKit
import ChauffeurCore

/// Direct app integration probe, enabled only in Debug with an isolated socket.
/// This checks our native views; it does not replace macOS UI automation/Spaces tests.
@MainActor enum NativeProbe {
    static var layouts: [UUID: ProjectLayout] = [:]
    static var openProject: ((UUID) -> Void)?
    private static var started = false
    static func start(model: AppModel) {
        guard !started, let path = ProcessInfo.processInfo.environment["CHAUFFEUR_NATIVE_PROBE_DIR"],
              model.socketPath == URL(fileURLWithPath: path).appendingPathComponent("runtime/runtime.sock").path else { return }
        started = true
        Task {
            let root = URL(fileURLWithPath: path)
            let phase = ProcessInfo.processInfo.environment["CHAUFFEUR_NATIVE_PROBE_PHASE"] ?? "1"
            do {
                if phase == "route" {
                    guard let project = ProcessInfo.processInfo.environment["CHAUFFEUR_ROUTE_PROJECT"].flatMap(UUID.init(uuidString:)),
                          let session = ProcessInfo.processInfo.environment["CHAUFFEUR_ROUTE_SESSION"].flatMap(UUID.init(uuidString:)) else {
                        throw ChauffeurError("native_probe", "Missing route fixture identity")
                    }
                    try await wait("cold-launch URL selected the session") {
                        model.online && layouts[project]?.window?.isVisible == true && layouts[project]?.state.selectedSessionID == session && model.pendingSessionRoute == nil
                    }
                    try await wait("cold-launch URL dismissed Welcome") {
                        !NSApp.windows.contains { $0.isVisible && $0.title == "Welcome to Chauffeur" }
                    }
                    guard layouts.count == 1, layouts[project]?.state.tabs == [session] else {
                        throw ChauffeurError("native_probe", "Cold-launch URL restored an unexpected project or tab")
                    }
                    layouts[project]?.window?.performClose(nil)
                    try await wait("route project closed") { !model.openProjects.contains(project) }
                    let missing = SessionRoute(projectID: UUID(), sessionID: UUID())
                    _ = try await NSWorkspace.shared.open([missing.url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
                    try await wait("missing notification target presented an error") {
                        model.error != nil && NSApp.windows.contains { $0.isVisible && $0.title == "Welcome to Chauffeur" }
                    }
                    model.error = nil
                    await model.finishPendingWindowWrites()
                    let result: JSONValue = .object(["passed": .bool(true), "phase": .string(phase), "routing": .string("Launch Services cold launch selected the recorded project/session with all project windows previously closed"), "processID": .number(Double(ProcessInfo.processInfo.processIdentifier))])
                    try JSONCoding.encode(result).write(to: root.appendingPathComponent("native-phase-route.json"), options: .atomic)
                    model.quit(); return
                }
                try await wait("four restored project windows") {
                    model.online && layouts.count == 4 && layouts.values.allSatisfy { $0.window?.isVisible == true }
                }
                guard model.snapshot.sessions.count == 10 else { throw ChauffeurError("native_probe", "Expected ten fixture sessions") }
                let diagnostics = await model.makeDiagnostics()
                let cached = model.cachedDiagnostics()
                let unavailable = AppModel().cachedDiagnostics()
                guard diagnostics.observation == .live, diagnostics.sessionCount == 10, diagnostics.logs.status == .available,
                      cached.observation == .cached, cached.observedAt == model.snapshotReceivedAt,
                      cached.logs.status == .notFetched, unavailable.observation == .unavailable else {
                    throw ChauffeurError("native_probe", "Diagnostics did not distinguish live, cached, and unavailable state")
                }
                try diagnostics.write(to: root.appendingPathComponent("diagnostics-phase-\(phase).json"))
                let ordered = layouts.values.sorted { model.project($0.state.id)!.name < model.project($1.state.id)!.name }
                for layout in ordered {
                    let original = layout.state
                    for id in original.tabs {
                        layout.select(id)
                        try await wait("rendered fixture terminal \(id)") {
                            guard let controller = layout.controllers[id] else { return false }
                            let text = screen(controller).replacingOccurrences(of: "\n", with: "")
                            return controller.connected && controller.terminal.window === layout.window && text.contains("Chauffeur fixture — 日本語 café")
                        }
                    }
                    // Restore selection without overwriting geometry saved while
                    // the real views were being laid out and resized.
                    layout.state.selectedSessionID = original.selectedSessionID
                    layout.state.splitSessionID = original.splitSessionID
                }
                let first = ordered[0]
                let selected = first.state.selectedSessionID!
                try await wait("restored split terminals") {
                    first.controllers[selected]?.connected == true && first.controllers[first.state.splitSessionID!]?.connected == true
                }
                let controller = first.controllers[selected]!
                if phase == "1" {
                    controller.terminal.insertText("native café 日本語", replacementRange: NSRange(location: NSNotFound, length: 0))
                    try await wait("native input echoed") { screen(controller).contains("INPUT=native café 日本語") }
                    let window = first.window!
                    window.setContentSize(NSSize(width: 1180, height: 760))
                    try await wait("terminal PTY resize") {
                        let terminal = controller.terminal.getTerminal()
                        return screen(controller).contains("SIZE=\(terminal.cols)x\(terminal.rows)")
                    }
                    controller.detach()
                    try await Task.sleep(for: .milliseconds(300))
                    controller.attach(socketPath: model.socketPath)
                }
                try await wait("reattached unsent input") { controller.connected && screen(controller).contains("INPUT=native café 日本語") }
                controller.find()
                try await wait("searchable normal terminal history") {
                    guard let history = controller.historyController else { return false }
                    return history.terminal.window != nil && history.terminal.findNext("fixture-history-249")
                }
                let history = controller.historyController!
                guard history.terminal.findNext("INPUT=native café 日本語") else { throw ChauffeurError("native_probe", "Active screen is missing from searchable history") }
                history.terminal.insertText("history-must-not-send", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(200))
                guard !screen(controller).contains("history-must-not-send") else { throw ChauffeurError("native_probe", "Read-only history sent terminal input") }
                controller.historyPresented = false
                try await wait("history view dismissed") { first.window?.attachedSheet == nil }
                if phase == "1" {
                    openProject?(first.state.id); openProject?(first.state.id)
                    try await Task.sleep(for: .milliseconds(300))
                    guard NSApp.windows.filter({ $0.isVisible && $0.identifier?.rawValue == "project-\(first.state.id.uuidString)" }).count == 1 else {
                        throw ChauffeurError("native_probe", "Opening the same project duplicated its window")
                    }
                    let closing = ordered[3], closingID = closing.state.id
                    closing.window?.performClose(nil)
                    try await wait("project window close") { !model.openProjects.contains(closingID) }
                    await model.finishPendingWindowWrites(); try await model.refresh()
                    guard model.snapshot.store.windows.first(where: { $0.value.id == closingID })?.value.wasOpen == false else {
                        throw ChauffeurError("native_probe", "Closing a window did not save its closed state")
                    }
                    let routedSession = closing.state.tabs.last!
                    closing.search = "does-not-match-any-session"
                    let route = SessionRoute(projectID: closingID, sessionID: routedSession)
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    _ = try await NSWorkspace.shared.open([route.url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
                    try await wait("closed project reopened") { layouts[closingID]?.window?.isVisible == true && model.openProjects.contains(closingID) }
                    try await wait("notification URL selected the recorded session") {
                        layouts[closingID]?.state.selectedSessionID == routedSession && layouts[closingID]?.search == "" && model.pendingSessionRoute == nil
                    }
                    _ = try await NSWorkspace.shared.open([route.url], withApplicationAt: Bundle.main.bundleURL, configuration: configuration)
                    try await wait("repeated notification URL consumed") { model.pendingSessionRoute == nil }
                    guard NSApp.windows.filter({ $0.isVisible && $0.identifier?.rawValue == "project-\(closingID.uuidString)" }).count == 1 else {
                        throw ChauffeurError("native_probe", "Notification URL duplicated its project window")
                    }
                }
                guard model.error == nil else { throw ChauffeurError("native_probe", model.error!) }
                if let view = first.window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("native-phase-\(phase).png")) }
                }
                try await Task.sleep(for: .milliseconds(400))
                await model.finishPendingWindowWrites()
                let result: JSONValue = .object(["passed": .bool(true), "phase": .string(phase), "windows": .number(4), "sessions": .number(10), "renderedTerminals": .number(10), "unsentInput": .string("preserved"), "historySearch": .string("normal history and active screen found; read-only input ignored"), "split": .bool(first.state.splitSessionID != nil), "frame": .string(NSStringFromRect(first.window!.frame))])
                try JSONCoding.encode(result).write(to: root.appendingPathComponent("native-phase-\(phase).json"), options: .atomic)
            } catch {
                let result: JSONValue = .object(["passed": .bool(false), "error": .string(error.localizedDescription), "appError": model.error.map(JSONValue.string) ?? .null, "layouts": .number(Double(layouts.count)), "windows": .array(NSApp.windows.map { .string($0.title) }), "terminals": .array(layouts.values.flatMap { $0.controllers.values }.map { .object(["id": .string($0.sessionID.uuidString), "connected": .bool($0.connected), "size": .string("\($0.terminal.getTerminal().cols)x\($0.terminal.getTerminal().rows)"), "status": $0.status.map(JSONValue.string) ?? .null, "historyPresented": .bool($0.historyPresented), "historyAttached": .bool($0.historyController?.terminal.window != nil), "historyStatus": $0.historyController?.status.map(JSONValue.string) ?? .null, "historyEvents": .array(($0.historyController?.debugEvents ?? []).map(JSONValue.string)), "historyTail": $0.historyController.map { .string(String(screen($0).suffix(4000))) } ?? .null, "screen": .string(screen($0))]) })])
                try? JSONCoding.encode(result).write(to: root.appendingPathComponent("native-phase-\(phase).json"), options: .atomic)
                let traces = Dictionary(uniqueKeysWithValues: layouts.values.flatMap { $0.controllers.values }.map { ($0.sessionID.uuidString, $0.debugEvents) })
                try? JSONCoding.encode(traces).write(to: root.appendingPathComponent("native-phase-\(phase)-trace.json"), options: .atomic)
            }
            if ProcessInfo.processInfo.environment["CHAUFFEUR_NATIVE_PROBE_HOLD"] != "1" { model.quit() }
        }
    }
    private static func screen(_ controller: TerminalController) -> String {
        // SwiftTerm exports NUL continuation cells after wide glyphs.
        String(decoding: controller.terminal.getTerminal().getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "")
    }
    private static func wait(_ label: String, until probe: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if probe() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChauffeurError("native_probe_timeout", "Timed out waiting for \(label)")
    }
}
#endif
