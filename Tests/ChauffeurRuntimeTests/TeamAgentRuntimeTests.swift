import Foundation
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

struct TeamAgentRuntimeTests {
    @Test func shellUsesTeamVariablesAfterLoginFilesAndNewShellsUseTeamEdits() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        try Data("export CODEX_HOME=/wrong\nexport CLAUDE_CONFIG_DIR=/wrong\n".utf8).write(to: fixture.root.appendingPathComponent(".zshrc"))
        var stored = try #require(await fixture.runtime.store.reload().presetSets.first)
        var team = stored.value
        team.configurationDirectories = ["codex": fixture.root.appendingPathComponent("missing-codex").path, "claude": fixture.root.path]
        stored = try await fixture.runtime.store.save(team, expectedVersion: stored.version)
        var settings = RetentionSettings(); settings.keepFinishedSessions = true
        _ = try await fixture.runtime.handle(IPCRequest("saveSettings", params: try .from(settings)))
        let request = LaunchRequest.shell(projectID: fixture.request.projectID, groupID: fixture.request.groupID, folderID: fixture.request.folderID, title: "Team Shell")
        let shell = try await fixture.runtime.launch(request)
        try await fixture.wait { try await fixture.activity(shell.id).idle }
        try fixture.sendKeys(sessionID: shell.id, "printf '%s\\n%s' \"$CODEX_HOME\" \"$CLAUDE_CONFIG_DIR\" > shell-env")
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("shell-env").path) }
        let expected = Paths.canonical(team.configurationDirectories!["codex"]!) + "\n" + Paths.canonical(fixture.root.path)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("shell-env"), encoding: .utf8) == expected)
        #expect(shell.launch.teamID == team.id && shell.launch.presetSetName == team.name)
        team = stored.value; team.configurationDirectories?["codex"] = "/changed"
        try await fixture.runtime.store.save(team, expectedVersion: stored.version)
        let next = try await fixture.runtime.launch(LaunchRequest.shell(projectID: fixture.request.projectID, groupID: fixture.request.groupID, folderID: fixture.request.folderID, title: "Changed Team Shell"))
        #expect(next.launch.configurationEnvironment?["CODEX_HOME"] == "/changed")
        try fixture.sendKeys(sessionID: shell.id, "printf '%s' \"$CODEX_HOME\" > unchanged-env")
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("unchanged-env").path) }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("unchanged-env"), encoding: .utf8) == shell.launch.configurationEnvironment?["CODEX_HOME"])

    }

    @Test func remoteInventoryAndLaunchResolveGlobalPresets() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let stored = try #require(await fixture.runtime.store.reload().presetSets.first)
        var team = stored.value; team.agentSelection = .allBase
        try await fixture.runtime.store.save(team, expectedVersion: stored.version)
        let base = BaseAgentPreset(name: "Remote base", kind: .claude, executable: fixture.root.appendingPathComponent("fixture.py").path)
        try await fixture.runtime.store.save(base)
        let handlers = RemoteOperationHandlers(runtime: fixture.runtime, root: fixture.root, hostName: "Fixture", isAttached: { _ in false })
        let inventory = try await handlers.inventory()
        #expect(inventory.projects.first?.presets.contains { $0.id == base.id } == true)
        let spec = LaunchSpec(projectID: fixture.request.projectID, folderID: fixture.request.folderID, agentPresetID: base.id)
        let operation = LaunchOperationRequest(operationKey: UUID(), fingerprint: LaunchOperationRequest.computeFingerprint(newWorktree: nil, launch: spec), launch: spec)
        let result = await handlers.launch(operation, deviceID: UUID())
        #expect(result.phase == .completed)
        let sessionID = try #require(result.sessionID)
        #expect(await fixture.runtime.store.reload().sessions.contains { $0.value.id == sessionID && $0.value.launch.preset.id == base.id })
    }

    @Test func globalPresetLaunchesAndSnapshotsStayFixedAfterBaseAndTeamEdits() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let stored = try #require(await fixture.runtime.store.reload().presetSets.first)
        var team = stored.value; team.agentSelection = .allBase; team.configurationDirectories = ["claude": fixture.root.path]
        let savedTeam = try await fixture.runtime.store.save(team, expectedVersion: stored.version)
        var base = BaseAgentPreset(name: "Global", kind: .claude, executable: fixture.root.appendingPathComponent("fixture.py").path)
        base.arguments = ["--model", "opus"]
        let savedBase = try await fixture.runtime.store.save(base)
        var request = fixture.request; request.presetID = base.id
        let session = try await fixture.runtime.launch(request)
        #expect(session.launch.preset.id == base.id)
        #expect(session.launch.configurationPath == Paths.canonical(fixture.root.path))
        #expect(session.launch.preset.baseRevision == savedBase.value.revision)
        #expect(session.launch.configurationEnvironment?["CLAUDE_CONFIG_DIR"] == Paths.canonical(fixture.root.path))
        #expect(await fixture.runtime.store.reload().projects.first?.value.lastPresetID == base.id)
        base.arguments = ["--model", "sonnet"]
        try await fixture.runtime.store.save(base, expectedVersion: savedBase.version)
        team = savedTeam.value; team.configurationDirectories?["claude"] = "/new-team-config"
        try await fixture.runtime.store.save(team, expectedVersion: savedTeam.version)
        let persisted = try #require(await fixture.runtime.store.reload().sessions.first { $0.value.id == session.id }?.value)
        #expect(persisted.launch.preset.arguments == ["--model", "opus"])
        #expect(persisted.launch.configurationPath == Paths.canonical(fixture.root.path))
        _ = try await fixture.runtime.handle(IPCRequest("terminalSnapshot", params: .object(["sessionID": .string(session.id.uuidString)])))
        _ = try await fixture.runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(session.id.uuidString), "force": .bool(true)])))
        // A stopped terminal must still expose its saved history before resume.
        _ = try await fixture.runtime.handle(IPCRequest("terminalSnapshot", params: .object(["sessionID": .string(session.id.uuidString)])))
        try await fixture.runtime.reconcile()
        let resumed = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(session.id.uuidString)]))).decode(Session.self)
        #expect(resumed.launch.configurationPath == session.launch.configurationPath)
        #expect(resumed.launch.configurationEnvironment == session.launch.configurationEnvironment)
        #expect(resumed.launch.preset.arguments == ["--model", "opus"])
    }
}
