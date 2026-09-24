#if DEBUG
import AppKit
import Combine
import ChauffeurCore
import ChauffeurTerminalInterface

/// Direct app integration probe, enabled only in Debug with an isolated socket.
/// This checks our native views; it does not replace macOS UI automation/Spaces tests.
@MainActor enum NativeProbe {
    static var layouts: [UUID: ProjectLayout] = [:]
    static var openProject: ((UUID) -> Void)?
    private static var started = false
    private static var errorObserver: AnyCancellable?
    static func start(model: AppModel) {
        guard !started, let path = ProcessInfo.processInfo.environment["CHAUFFEUR_NATIVE_PROBE_DIR"],
              model.socketPath == URL(fileURLWithPath: path).appendingPathComponent("runtime/runtime.sock").path else { return }
        started = true
        // Surface presented app errors in the captured app log, since a modal
        // alert leaves no other trace when a phase stalls.
        errorObserver = model.$error.sink { message in
            if let message { FileHandle.standardError.write(Data("[native-probe] app error: \(message)\n".utf8)) }
        }
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
                        !NSApp.windows.contains { $0.isVisible && $0.title == "Welcome to \(AppBuild.current.displayName)" }
                    }
                    guard layouts.count == 1, layouts[project]?.state.selectedSessionID == session,
                          layouts[project]?.state.selectedWorktreePath == model.session(session)?.launch.workingDirectory else {
                        throw ChauffeurError("native_probe", "Cold-launch URL restored an unexpected project or checkout")
                    }
                    layouts[project]?.window?.performClose(nil)
                    try await wait("route project closed") { !model.openProjects.contains(project) }
                    let missing = SessionRoute(projectID: UUID(), sessionID: UUID())
                    _ = try await NSWorkspace.shared.open([missing.url], withApplicationAt: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
                    try await wait("missing notification target presented an error") {
                        model.error != nil && NSApp.windows.contains { $0.isVisible && $0.title == "Welcome to \(AppBuild.current.displayName)" }
                    }
                    model.error = nil
                    await model.finishPendingWindowWrites()
                    let result: JSONValue = .object(["passed": .bool(true), "phase": .string(phase), "routing": .string("Launch Services cold launch selected the recorded project/session with all project windows previously closed"), "processID": .number(Double(ProcessInfo.processInfo.processIdentifier))])
                    try JSONCoding.encode(result).write(to: root.appendingPathComponent("native-phase-route.json"), options: .atomic)
                    model.isTerminating = true; model.quit(); return
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
                    guard let folder = model.project(layout.state.id)?.folders.first else { throw ChauffeurError("native_probe", "Fixture project has no folder") }
                    for session in model.sessions(in: layout.state.id) {
                        layout.selectSession(session.id, folderID: folder.id, path: session.launch.workingDirectory)
                        try await wait("rendered fixture terminal \(session.id)") {
                            guard let controller = layout.controllers[session.id] else { return false }
                            let text = screen(controller).replacingOccurrences(of: "\n", with: "")
                            return controller.connected && controller.view.window === layout.window && text.contains("Chauffeur fixture — 日本語 café")
                        }
                    }
                    // Restore selection without overwriting geometry saved while
                    // the real views were being laid out and resized.
                    layout.state.selectedSessionID = original.selectedSessionID
                    layout.state.selectedFolderID = original.selectedFolderID
                    layout.state.selectedWorktreePath = original.selectedWorktreePath
                }
                let first = ordered[0]
                let selected = first.state.selectedSessionID!
                try await wait("restored selected terminal") {
                    first.controllers[selected]?.connected == true && first.controllers.values.filter(\.connected).count == 1
                }
                let controller = first.controllers[selected]!
                if phase == "1" {
                    // A transient socket loss must recover without a button or
                    // a new snapshot. Leaving the tab cancels a pending retry.
                    controller.simulateConnectionDrop()
                    try await wait("terminal scheduled automatic reconnect") { !controller.connected && controller.status == "Reconnecting…" }
                    controller.detach()
                    try await Task.sleep(for: .milliseconds(600))
                    guard controller.controlState == .detached && !controller.connected else {
                        throw ChauffeurError("native_probe", "Detached terminal retried in the background")
                    }
                    // Model a runtime socket that appears after the first attach.
                    let delayedSocket = root.appendingPathComponent("delayed.sock")
                    controller.attach(socketPath: delayedSocket.path)
                    try await wait("unavailable runtime scheduled reconnect") { controller.status == "Reconnecting…" }
                    try FileManager.default.createSymbolicLink(atPath: delayedSocket.path, withDestinationPath: model.socketPath)
                    try await wait("terminal recovered when runtime became available") { controller.connected }
                    controller.simulateConnectionDrop()
                    try await wait("dropped stream scheduled reconnect") { !controller.connected && controller.status == "Reconnecting…" }
                    try await wait("dropped stream recovered automatically") { controller.connected }
                    controller.simulateTyping("native café 日本語")
                    try await wait("native input echoed") { screen(controller).contains("INPUT=native café 日本語") }
                    let window = first.window!
                    window.setContentSize(NSSize(width: 1180, height: 760))
                    try await wait("terminal PTY resize") {
                        let size = controller.adapter.cellSize
                        return screen(controller).contains("SIZE=\(size.cols)x\(size.rows)")
                    }
                    // Zoom and a new default style apply to the live terminal in
                    // place: the grid changes, the process sees the resize, and
                    // the screen keeps its text.
                    let unzoomed = controller.adapter.cellSize
                    controller.adjustFontSize(by: 4)
                    try await wait("zoomed terminal resized its process") {
                        let size = controller.adapter.cellSize
                        return size.cols < unzoomed.cols && screen(controller).contains("SIZE=\(size.cols)x\(size.rows)")
                    }
                    // Compare with the zoomed grid: the window may still have been
                    // settling its own resize when `unzoomed` was read.
                    let zoomed = controller.adapter.cellSize
                    controller.resetFontSize()
                    try await wait("zoom reset grew the grid back") {
                        let size = controller.adapter.cellSize
                        return size.cols > zoomed.cols && screen(controller).contains("SIZE=\(size.cols)x\(size.rows)")
                    }
                    let unstyled = controller.adapter.cellSize
                    let original = controller.style
                    controller.setStyle(TerminalStyle(fontFamily: "Menlo", fontSize: original.fontSize + 5, light: .named("Nord Light"), dark: .named("Nord")))
                    try await wait("restyled terminal kept its screen") {
                        let size = controller.adapter.cellSize
                        return size.cols < unstyled.cols && screen(controller).contains("INPUT=native café 日本語")
                            && screen(controller).contains("SIZE=\(size.cols)x\(size.rows)")
                    }
                    controller.setStyle(original)
                    try await wait("original style restored the grid") { controller.adapter.cellSize == unstyled }
                    // Colors follow the app's appearance, a style change resets a
                    // zoomed terminal, and custom colors reach the screen.
                    let savedAppearance = NSApp.appearance
                    NSApp.appearance = NSAppearance(named: .aqua)
                    controller.adjustFontSize(by: 3)
                    try await wait("zoomed before restyling") { controller.adapter.cellSize.cols < unstyled.cols }
                    let themed = TerminalStyle(fontFamily: nil, fontSize: original.fontSize, light: .named("Solarized Light"), dark: .named("Tokyo Night"))
                    controller.setStyle(themed)
                    try await wait("zoom reset by the new style") { controller.adapter.cellSize == unstyled }
                    try await expectBackground("#fdf6e3", of: controller, in: root, step: "light-theme")
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                    try await expectBackground("#1a1b26", of: controller, in: root, step: "dark-theme")
                    var custom = TerminalThemeCatalog.theme(named: "Tokyo Night")!
                    custom.background = "#2d1b4e"
                    controller.setStyle(TerminalStyle(fontFamily: nil, fontSize: original.fontSize, light: themed.light, dark: .custom(custom)))
                    try await expectBackground("#2d1b4e", of: controller, in: root, step: "custom-colors")
                    NSApp.appearance = NSAppearance(named: .aqua)
                    try await expectBackground("#fdf6e3", of: controller, in: root, step: "light-again")
                    NSApp.appearance = savedAppearance
                    controller.setStyle(original)
                    controller.detach()
                    try await Task.sleep(for: .milliseconds(300))
                    controller.attach(socketPath: model.socketPath)
                }
                try await wait("reattached unsent input") { controller.connected && screen(controller).contains("INPUT=native café 日本語") }
                controller.find()
                try await wait("searchable normal terminal history") {
                    guard let history = controller.historyController else { return false }
                    return history.view.window != nil && screen(history).contains("fixture-history-249")
                }
                let history = controller.historyController!
                guard screen(history).contains("INPUT=native café 日本語") else { throw ChauffeurError("native_probe", "Active screen is missing from searchable history") }
                history.search("fixture-history-249")
                try await wait("history search found a match") { (history.searchTotal ?? 0) > 0 }
                history.closeFind()
                history.simulateTyping("history-must-not-send")
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
                    let routedSession = model.sessions(in: closingID).last!.id
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
                let result: JSONValue = .object(["passed": .bool(false), "error": .string(error.localizedDescription), "appError": model.error.map(JSONValue.string) ?? .null, "layouts": .number(Double(layouts.count)), "windows": .array(NSApp.windows.map { .string($0.title) }), "terminals": .array(layouts.values.flatMap { $0.controllers.values }.map { .object(["id": .string($0.sessionID.uuidString), "connected": .bool($0.connected), "size": .string("\($0.adapter.cellSize.cols)x\($0.adapter.cellSize.rows)"), "status": $0.status.map(JSONValue.string) ?? .null, "historyPresented": .bool($0.historyPresented), "historyAttached": .bool($0.historyController?.view.window != nil), "historyStatus": $0.historyController?.status.map(JSONValue.string) ?? .null, "historyEvents": .array(($0.historyController?.debugEvents ?? []).map(JSONValue.string)), "historyTail": $0.historyController.map { .string(String(screen($0).suffix(4000))) } ?? .null, "screen": .string(screen($0))]) })])
                try? JSONCoding.encode(result).write(to: root.appendingPathComponent("native-phase-\(phase).json"), options: .atomic)
                let traces = Dictionary(uniqueKeysWithValues: layouts.values.flatMap { $0.controllers.values }.map { ($0.sessionID.uuidString, $0.debugEvents) })
                try? JSONCoding.encode(traces).write(to: root.appendingPathComponent("native-phase-\(phase)-trace.json"), options: .atomic)
            }
            if ProcessInfo.processInfo.environment["CHAUFFEUR_NATIVE_PROBE_HOLD"] != "1" {
                // This isolated probe leaves its fake agents running. The quit
                // confirmation itself belongs to the UI automation tests.
                model.isTerminating = true
                model.quit()
            }
        }
    }
    /// Waits until the terminal's on-screen background near its bottom-right corner is `hex`.
    /// The smoke script takes the screen capture; Metal output cannot be read back in-process.
    private static func expectBackground(_ hex: String, of controller: TerminalController, in root: URL, step: String) async throws {
        var sampled = "nothing"
        for attempt in 0..<40 {
            let view = controller.view
            guard let window = view.window else { break }
            // An occluded surface stops rendering; bring the window forward without activating.
            window.orderFrontRegardless()
            // The view in window coordinates (bottom-left origin over the whole frame).
            let rect = view.convert(view.bounds, to: nil)
            let name = "\(step)-\(attempt)"
            let capture = root.appendingPathComponent("capture-\(name).png")
            try JSONSerialization.data(withJSONObject: ["name": name, "window": window.windowNumber] as [String: Any])
                .write(to: root.appendingPathComponent("capture-request.json"))
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: capture.path) { try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .milliseconds(100))
            if let bitmap = NSBitmapImageRep(data: (try? Data(contentsOf: capture)) ?? Data()), window.frame.width > 0 {
                let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
                let x = Int((rect.maxX - 10) * scale), y = Int((window.frame.height - rect.minY - 10) * scale)
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                sampled = color.terminalHex
                try? FileManager.default.removeItem(at: capture)
                // Ghostty converts colors into a Display P3 surface; dark colors land a few
                // percent lighter on screen. The steps below differ by at least 0.16 per channel.
                if colorDistance(sampled, hex) < 0.08 { return }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ChauffeurError("native_probe", "Terminal background for \(step) is \(sampled), expected \(hex)")
    }
    private static func colorDistance(_ lhs: String, _ rhs: String) -> Double {
        func components(_ hex: String) -> [Double] {
            let value = UInt32(hex.drop { $0 == "#" }, radix: 16) ?? 0
            return [value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff].map { Double($0) / 255 }
        }
        return zip(components(lhs), components(rhs)).map { abs($0 - $1) }.max() ?? 1
    }
    private static func screen(_ controller: TerminalController) -> String {
        controller.screenText
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
