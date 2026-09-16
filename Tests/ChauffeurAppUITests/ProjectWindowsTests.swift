import XCTest
import Foundation
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
        runtime.standardOutput = FileHandle.nullDevice; runtime.standardError = FileHandle.nullDevice
        try runtime.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if let health = try? await call("status"), health["mcpEndpoint"].string != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await call("status")
        let set = PresetSet(name: "Fixture Personal")
        _ = try await call("savePresetSet", .object(["record": try .from(set)]))
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let config = root.appendingPathComponent("existing fixture profile")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let preset = AgentPreset(setID: set.id, name: "Fake Codex", kind: .codex, executable: sourceRoot.appendingPathComponent("Prototypes/fake_cli.py").path, configurationDirectory: config.path)
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
            _ = try await call("saveWindow", .object(["record": try .from(window)]))
            projects.append(project)
        }
        app = XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle(url: appURL)?.bundleIdentifier))
        app.launchEnvironment["CHAUFFEUR_SOCKET"] = socketPath
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }
    override func tearDown() async throws {
        app?.terminate()
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
    private func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue { try await RuntimeClient.call(IPCRequest(method, params: params), socketPath: socketPath) }
}
