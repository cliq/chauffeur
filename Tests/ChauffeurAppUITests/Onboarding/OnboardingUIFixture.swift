import XCTest
import Foundation
import ChauffeurCore

@MainActor final class OnboardingUIFixture {
    private(set) var app: XCUIApplication!
    private(set) var runtime: Process!
    private(set) var root: URL!
    private(set) var socketPath: String!
    private(set) var executable: URL!
    private(set) var profile: URL!

    func start() async throws {
        root = URL(fileURLWithPath: "/tmp/chauffeur-onboarding-ui-\(UUID().uuidString.prefix(8))")
        let home = root.appendingPathComponent("home")
        let temporary = root.appendingPathComponent("tmp")
        profile = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("fake-codex")
        try writeFakeCodex(to: executable)

        socketPath = root.appendingPathComponent("runtime/runtime.sock").path
        let applicationPath = try XCTUnwrap(ProcessInfo.processInfo.environment["CHAUFFEUR_TEST_APP"])
        let appURL = URL(fileURLWithPath: applicationPath)
        runtime = Process()
        runtime.executableURL = appURL.appendingPathComponent("Contents/MacOS/ChauffeurRuntime")
        runtime.arguments = ["--data-dir", root.path]
        runtime.currentDirectoryURL = root
        runtime.environment = [
            "HOME": home.path,
            "TMPDIR": temporary.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "CHAUFFEUR_CODEX_EXECUTABLE": executable.path,
            "SHELL": "/bin/sh",
            "TERM": "xterm-256color"
        ]
        runtime.standardOutput = FileHandle.nullDevice
        runtime.standardError = FileHandle.nullDevice
        try runtime.run()

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if let health = try? await call("status"), health["mcpEndpoint"].string != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try await call("status")

        app = XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle(url: appURL)?.bundleIdentifier))
        app.launchEnvironment["CHAUFFEUR_SOCKET"] = socketPath
        app.launchEnvironment["HOME"] = home.path
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    }

    func stop() async {
        app?.terminate()
        if runtime?.isRunning == true {
            runtime.terminate()
            runtime.waitUntilExit()
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func launch() {
        app.launch()
    }

    func openWizard() {
        if app.staticTexts["Set up your teams"].waitForExistence(timeout: 3) { return }
        let open = app.buttons["onboarding.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.click()
        XCTAssertTrue(app.staticTexts["Set up your teams"].waitForExistence(timeout: 10))
    }

    func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await RuntimeClient.call(IPCRequest(method, params: params), socketPath: socketPath)
    }

    @discardableResult
    func seedDraft(_ draft: SetupDraft) async throws -> Stored<SetupDraft> {
        try await call("saveSetupDraft", .object([
            "record": try .from(draft),
            "expectedVersion": .null
        ])).decode(Stored<SetupDraft>.self)
    }

    func setupDraft() async throws -> Stored<SetupDraft> {
        let stored = try await call("setupDraft").decode(Optional<Stored<SetupDraft>>.self)
        return try XCTUnwrap(stored)
    }

    func seedReturningProject(name: String) async throws -> Project {
        let team = PresetSet(name: "Existing Team")
        _ = try await call("savePresetSet", .object(["record": try .from(team)]))
        var project = Project(name: name, presetSetID: team.id)
        let folderURL = root.appendingPathComponent("existing-repository")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        project.addFolder(ProjectFolder(path: folderURL.path))
        _ = try await call("saveProject", .object(["record": try .from(project)]))
        var window = WindowState(projectID: project.id)
        window.selectedFolderID = project.folders.first?.id
        window.wasOpen = true
        _ = try await call("saveWindow", .object(["record": try .from(window)]))
        return project
    }

    private func writeFakeCodex(to url: URL) throws {
        let script = #"""
        #!/bin/sh
        case "$1 $2" in
          "login --help")
            printf 'Commands:\n  status  Show login status\n'
            exit 0
            ;;
          "login status")
            if [ -f "$CODEX_HOME/.fixture-authenticated" ]; then
              printf 'Logged in using ChatGPT\n' >&2
              exit 0
            fi
            printf 'Not logged in\n' >&2
            exit 1
            ;;
        esac
        if [ "$1" = "login" ]; then
          mkdir -p "$CODEX_HOME"
          : > "$CODEX_HOME/.fixture-authenticated"
          printf 'Fixture sign-in complete.\n'
          exit 0
        fi
        printf 'Unsupported fixture command\n' >&2
        exit 2
        """#
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

extension XCUIElement {
    func replaceText(with value: String) {
        click()
        typeKey("a", modifierFlags: .command)
        typeText(value)
    }
}
