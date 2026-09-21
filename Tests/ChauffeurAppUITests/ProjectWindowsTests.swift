import XCTest
import Foundation
import AppKit
import ChauffeurCore

/// Exercises actual native windows and terminal views against an isolated runtime.
/// Provider-backed and separate-Spaces acceptance remains a manual release gate.
@MainActor final class ProjectWindowsTests: XCTestCase {
    private var app: XCUIApplication!
    private var runtime: Process!
    private var root: URL!
    private var socketPath: String!
    private var projects: [Project] = []
    private var sessions: [Session] = []

    override func setUp() async throws {
        continueAfterFailure = false
        root = URL(fileURLWithPath: "/tmp/chauffeur-ui-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        socketPath = root.appendingPathComponent("runtime/runtime.sock").path
        let applicationPath = try XCTUnwrap(ProcessInfo.processInfo.environment["CHAUFFEUR_TEST_APP"])
        let appURL = URL(fileURLWithPath: applicationPath)
        runtime = Process(); runtime.executableURL = appURL.appendingPathComponent("Contents/MacOS/ChauffeurRuntime")
        runtime.arguments = ["--data-dir", root.path]
        runtime.currentDirectoryURL = root
        runtime.standardOutput = FileHandle.nullDevice; runtime.standardError = FileHandle.nullDevice
        try runtime.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if let health = try? await call("status"), health["mcpEndpoint"].string != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await call("status")
        let set = PresetSet(name: "Fixture Personal", agentSelection: .custom)
        _ = try await call("savePresetSet", .object(["record": try .from(set)]))
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let config = root.appendingPathComponent("existing fixture profile")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        for name in ["fake_cli.py", "fake_tui.py"] {
            let destination = root.appendingPathComponent(name)
            try Data(contentsOf: sourceRoot.appendingPathComponent("Prototypes/\(name)")).write(to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
        let preset = AgentPreset(setID: set.id, name: "Fake Codex", kind: .codex, executable: root.appendingPathComponent("fake_cli.py").path, configurationDirectory: config.path)
        _ = try await call("savePreset", .object(["record": try .from(preset)]))
        for index in 1...4 {
            var project = Project(name: "Window Fixture \(index)", presetSetID: set.id)
            let folderPath = root.appendingPathComponent("repo-\(index)")
            try FileManager.default.createDirectory(at: folderPath, withIntermediateDirectories: true)
            let folder = ProjectFolder(path: folderPath.path); project.addFolder(folder)
            _ = try await call("saveProject", .object(["record": try .from(project)]))
            var window = WindowState(projectID: project.id)
            for number in 1...(index <= 2 ? 3 : 2) {
                let launch = LaunchRequest(projectID: project.id, groupID: project.groups[0].id, presetID: preset.id, folderID: folder.id, title: "Terminal \(index).\(number)", allowSharedCheckout: true)
                let session = try await call("launch", .from(launch)).decode(Session.self)
                sessions.append(session)
                if window.selectedSessionID == nil { window.selectedSessionID = session.id }
            }
            window.selectedFolderID = folder.id; window.selectedWorktreePath = folder.canonicalPath; window.wasOpen = true
            // Keep fixtures on the main display instead of inheriting window positions
            // from a developer's multi-monitor workspace.
            let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            window.frame = NSStringFromRect(NSRect(x: screen.minX + 20, y: screen.minY + 20, width: 1000, height: 700))
            _ = try await call("saveWindow", .object(["record": try .from(window)]))
            projects.append(project)
        }
        app = XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle(url: appURL)?.bundleIdentifier))
        app.launchEnvironment["CHAUFFEUR_SOCKET"] = socketPath
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }
    override func tearDown() async throws {
        app?.terminate()
        if runtime?.isRunning == true { kill(runtime.processIdentifier, SIGCONT) }
        for session in sessions { _ = try? await call("stop", .object(["sessionID": .string(session.id.uuidString), "force": .bool(true)])) }
        if runtime?.isRunning == true { runtime.terminate(); runtime.waitUntilExit() }
        if let root {
            let tmux = Process(); tmux.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
            tmux.arguments = ["-S", root.appendingPathComponent("runtime/tmux.sock").path, "kill-server"]
            tmux.standardOutput = FileHandle.nullDevice; tmux.standardError = FileHandle.nullDevice
            try? tmux.run(); tmux.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
    }
    func testFourWindowsTenSessionsAndUIRelaunch() async throws {
        let before = try await call("snapshot")
        app.launch()
        for project in projects { XCTAssertTrue(app.windows[project.name].waitForExistence(timeout: 15)) }
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Window Fixture")).count, 4)
        let firstWindow = app.windows[projects[0].name]
        XCTAssertTrue(firstWindow.staticTexts["Terminal 1.1"].firstMatch.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: firstWindow.screenshot()); screenshot.name = "Project with checkout session strip"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
        let detached = try await call("snapshot")
        XCTAssertEqual(before["health"]["runtimeID"], detached["health"]["runtimeID"])
        XCTAssertEqual(Set(before["sessions"].array.compactMap { $0["processID"].int }), Set(detached["sessions"].array.compactMap { $0["processID"].int }))
        XCTAssertEqual(detached["sessions"].array.filter { $0["state"].string == "activityUnknown" }.count, 10)
        app.launch()
        for project in projects { XCTAssertTrue(app.windows[project.name].waitForExistence(timeout: 15)) }
        let restored = try await call("snapshot")
        XCTAssertEqual(before["sessions"].array.count, restored["sessions"].array.count)
        XCTAssertEqual(Set(before["sessions"].array.compactMap { $0["processID"].int }), Set(restored["sessions"].array.compactMap { $0["processID"].int }))
    }
    func testStartupWaitsForServiceBeforeRestoringProjects() async throws {
        let socket = URL(fileURLWithPath: socketPath)
        let waiting = socket.appendingPathExtension("waiting")
        try FileManager.default.moveItem(at: socket, to: waiting)
        defer {
            if FileManager.default.fileExists(atPath: waiting.path) {
                try? FileManager.default.moveItem(at: waiting, to: socket)
            }
        }
        app.launch()
        let welcome = app.windows["Welcome to Chauffeur Debug"]
        XCTAssertTrue(welcome.staticTexts["Opening your workspace…"].waitForExistence(timeout: 5))
        XCTAssertFalse(welcome.buttons["Start Service"].exists)
        XCTAssertFalse(welcome.textFields["projects.search"].exists)
        // A service that never arrives must expose recovery instead of spinning forever.
        XCTAssertTrue(welcome.buttons["Start Service"].waitForExistence(timeout: 20))
        XCTAssertFalse(welcome.staticTexts["Opening your workspace…"].exists)
        try FileManager.default.moveItem(at: waiting, to: socket)
        for project in projects { XCTAssertTrue(app.windows[project.name].waitForExistence(timeout: 15)) }
        XCTAssertTrue(welcome.waitForNonExistence(timeout: 5))
    }

    func testProjectSearchKeyboardNavigationAndReset() async throws {
        app.launch()
        XCTAssertTrue(app.windows[projects[0].name].waitForExistence(timeout: 15))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let appURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["CHAUFFEUR_TEST_APP"]))
        _ = try await NSWorkspace.shared.open([WelcomeRoute.url], withApplicationAt: appURL, configuration: configuration)
        let search = app.textFields["projects.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        app.typeText("Window Fixture")
        XCTAssertEqual(search.value as? String, "Window Fixture")
        app.typeKey(.downArrow, modifierFlags: [])
        let openButton = app.buttons["Open Project"]
        XCTAssertTrue(openButton.isEnabled)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "")
        XCTAssertFalse(openButton.isEnabled)
        app.typeText("no matching project")
        XCTAssertEqual(search.value as? String, "no matching project")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertFalse(openButton.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows[projects[0].name].exists)
    }

    func testRemovedSessionSelectsItsLeftNeighbor() async throws {
        app.launch()
        let window = app.windows[projects[0].name]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuBarItems["Window"].menus.menuItems[projects[0].name].click()
        let closing = window.buttons["session.card.\(sessions[1].id.uuidString)"]
        XCTAssertTrue(closing.waitForExistence(timeout: 10))
        closing.click()
        // A service-side close exercises selection recovery independently of Cmd-W.
        _ = try await call("closeSession", .object(["sessionID": .string(sessions[1].id.uuidString)]))
        XCTAssertTrue(closing.waitForNonExistence(timeout: 10))
        let left = window.buttons["session.card.\(sessions[0].id.uuidString)"]
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: left)
        await fulfillment(of: [selected], timeout: 10)
        XCTAssertFalse(window.staticTexts["No sessions on this worktree"].exists)
    }

    func testTabCreationAndClosureDoNotWaitForRuntime() async throws {
        continueAfterFailure = true
        app.launch()
        let window = app.windows[projects[0].name]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuBarItems["Window"].menus.menuItems[projects[0].name].click()
        let first = window.buttons["session.card.\(sessions[0].id.uuidString)"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.click()

        // Agent confirmation is local. Pause the runtime before confirming cleanup.
        app.typeKey("w", modifierFlags: .command)
        let confirmation = window.sheets.buttons["Close Tab"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        kill(runtime.processIdentifier, SIGSTOP)
        defer { kill(runtime.processIdentifier, SIGCONT) }
        confirmation.click()
        XCTAssertTrue(first.waitForNonExistence(timeout: 2))

        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: [])
        let pending = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.pending.")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 2))
        XCTAssertTrue(pending.isSelected)
        let pendingID = String(pending.identifier.dropFirst("session.pending.".count))
        XCTAssertTrue(window.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Starting Shell")).firstMatch.exists)
        kill(runtime.processIdentifier, SIGCONT)
        XCTAssertTrue(pending.waitForNonExistence(timeout: 15))
        let snapshot = try await call("snapshot")
        let shell = try XCTUnwrap(try snapshot["sessions"].array.map { try $0.decode(Session.self) }.first { $0.projectID == projects[0].id && !$0.launch.preset.kind.isAgent })
        sessions.append(shell)
        XCTAssertEqual(shell.id.uuidString, pendingID, "Loading and live tabs must share one identity")
        XCTAssertTrue(window.buttons["session.card.\(shell.id.uuidString)"].isSelected)
    }

    func testTabShortcutsStayInSelectedWindow() async throws {
        app.launch()
        let window = app.windows[projects[0].name]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuBarItems["Window"].menus.menuItems[projects[0].name].click()
        let firstCard = window.buttons["session.card.\(sessions[0].id.uuidString)"]
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        firstCard.click()
        let secondCard = window.buttons["session.card.\(sessions[1].id.uuidString)"]
        app.typeKey(.tab, modifierFlags: .control)
        XCTAssertTrue(secondCard.isSelected)
        app.typeKey(.tab, modifierFlags: [.control, .shift])
        XCTAssertTrue(firstCard.isSelected)


        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(window.buttons["new-tab.terminal"].waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(window.buttons["new-tab.terminal"].exists)

        // Send Command with both chord keys. typeKey's explicit modifier flags
        // override perform(withKeyModifiers:), so each event must include it.
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("t", modifierFlags: .command)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var shell: Session?
        while ContinuousClock.now < deadline {
            let snapshot = try await call("snapshot")
            shell = try snapshot["sessions"].array.map { try $0.decode(Session.self) }
                .first { $0.projectID == projects[0].id && !$0.launch.preset.kind.isAgent }
            if shell != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let terminal = try XCTUnwrap(shell)
        sessions.append(terminal)
        XCTAssertTrue(window.buttons["session.card.\(terminal.id.uuidString)"].waitForExistence(timeout: 10))

        app.typeKey("t", modifierFlags: .command)
        app.typeKey("a", modifierFlags: [])
        XCTAssertTrue(window.sheets.firstMatch.waitForExistence(timeout: 5))
        window.sheets.buttons["Cancel"].click()

        // The shell sits at its own prompt, so it closes without confirmation.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.buttons["session.card.\(terminal.id.uuidString)"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(window.sheets.firstMatch.exists)
        XCTAssertTrue(window.buttons["session.card.\(sessions[2].id.uuidString)"].isSelected)
        // Closing the final tab leaves its window open until the next Cmd-W.
        for _ in 0..<3 {
            app.typeKey("w", modifierFlags: .command)
            let confirmation = window.sheets.buttons["Close Tab"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            confirmation.click()
        }
        XCTAssertTrue(window.exists)
        XCTAssertEqual(window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.card.")).count, 0)
        // Tab disappearance now precedes background session cleanup.
        let remainingSessionCount = sessions.count - 4
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        var snapshot = try await call("snapshot")
        while snapshot["sessions"].array.count != remainingSessionCount && ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(100))
            snapshot = try await call("snapshot")
        }
        XCTAssertEqual(snapshot["sessions"].array.count, remainingSessionCount)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.windows[projects[1].name].exists)
    }
    private func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue { try await RuntimeClient.call(IPCRequest(method, params: params), socketPath: socketPath) }
}
