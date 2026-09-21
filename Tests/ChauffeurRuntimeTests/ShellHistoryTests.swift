import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct ShellHistoryTests {
    @Test(arguments: [false, true], [false, true])
    func newShellRecallsExistingHistory(customHistory: Bool, customDotDirectory: Bool) async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let dotDirectory = customDotDirectory ? fixture.path("shell-config") : fixture.root
        try FileManager.default.createDirectory(at: dotDirectory, withIntermediateDirectories: true)
        if customDotDirectory {
            try Data("export ZDOTDIR=\(ShellAgentEnvironment.shellQuoted(dotDirectory.path))\n".utf8).write(to: fixture.path(".zshenv"))
        }
        let history = dotDirectory.appendingPathComponent(customHistory ? "custom-history" : ".zsh_history")
        let rc = customHistory ? "HISTFILE=\(ShellAgentEnvironment.shellQuoted(history.path))\n" : ""
        try Data(rc.utf8).write(to: dotDirectory.appendingPathComponent(".zshrc"))
        // Pressing Up in the newly opened shell must retrieve and execute this command.
        try Data("printf recalled > \(ShellAgentEnvironment.shellQuoted(fixture.path("recalled").path))\n".utf8).write(to: history)
        let stored = try #require(await fixture.runtime.store.reload().presetSets.first)
        var team = stored.value
        team.configurationDirectories = ["codex": fixture.root.path]
        try await fixture.runtime.store.save(team, expectedVersion: stored.version)
        let shell = try await fixture.runtime.launch(.shell(projectID: fixture.request.projectID, groupID: fixture.request.groupID, folderID: fixture.request.folderID, title: "History"))
        try await fixture.wait { try await fixture.activity(shell.id).idle }
        try fixture.sendKeys(sessionID: shell.id, "Up")
        try fixture.sendKeys(sessionID: shell.id, "printf '%s' \"$HISTFILE\" > active-history")
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("active-history").path) }
        #expect(try String(contentsOf: fixture.path("active-history"), encoding: .utf8) == history.path)
        #expect(FileManager.default.fileExists(atPath: fixture.path("recalled").path))
    }
}
