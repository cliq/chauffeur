import ChauffeurCore
import Foundation
import Testing
@testable import ChauffeurRuntimeKit

private struct CoordinatorFakeAuthentication: AgentAuthentication {
    var result = SetupAuthStatus(
        phase: .connected,
        email: "fixture@example.test",
        organization: "Fixture Org",
        method: "test",
        checkedAt: Date()
    )

    func loginCommand(context: AuthenticationContext) async throws -> SetupCommand {
        SetupCommand(
            executable: "/bin/sh",
            arguments: ["-c", "exit 0"],
            directory: context.workingDirectory,
            environment: ["PATH": "/usr/bin:/bin", "HOME": context.baseEnvironment["HOME"] ?? "/tmp", "TERM": "xterm-256color"]
        )
    }

    func status(context: AuthenticationContext) async -> SetupAuthStatus { result }
}

private struct CoordinatorFakeMigration: ConfigurationMigration {
    func preview(pair: SetupAgentPair) throws -> CopyPreview {
        CopyPreview(
            pairID: pair.id,
            sourcePath: pair.sourcePath,
            destinationPath: Paths.canonical(pair.destinationPath),
            selectionDigest: "fixture-\(pair.id.uuidString)"
        )
    }

    func write(preview: CopyPreview, pair: SetupAgentPair, staging: URL) throws {
        try Data("fixture = true\n".utf8).write(to: staging.appendingPathComponent("settings.toml"), options: .withoutOverwriting)
    }
}

struct OnboardingCoordinatorTests {
    private struct Fixture {
        let root: URL
        let home: URL
        let store: FileStore
        let coordinator: OnboardingCoordinator
    }

    private func fixture(_ label: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-onboarding-coordinator-\(label)-\(UUID())")
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try FileStore(root: root.appendingPathComponent("store"))
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let coordinator = try OnboardingCoordinator(
            store: store,
            root: root.appendingPathComponent("store"),
            environment: environment,
            home: home,
            authentication: [.codex: CoordinatorFakeAuthentication()],
            migrations: [.codex: CoordinatorFakeMigration()]
        )
        return Fixture(root: root, home: home, store: store, coordinator: coordinator)
    }

    private func save(_ draft: SetupDraft, version: String? = nil, using coordinator: OnboardingCoordinator) async throws -> Stored<SetupDraft> {
        let result = try await coordinator.handle(IPCRequest("saveSetupDraft", params: .object([
            "record": try .from(draft),
            "expectedVersion": version.map(JSONValue.string) ?? .null
        ])))
        return try result.decode(Stored<SetupDraft>.self)
    }

    private func call(
        _ method: String, draftID: UUID, pairID: UUID? = nil,
        version: String? = nil, extra: [String: JSONValue] = [:],
        using coordinator: OnboardingCoordinator
    ) async throws -> JSONValue {
        var values: [String: JSONValue] = ["draftID": .string(draftID.uuidString)]
        if let pairID { values["pairID"] = .string(pairID.uuidString) }
        if let version { values["expectedVersion"] = .string(version) }
        for (key, value) in extra { values[key] = value }
        return try await coordinator.handle(IPCRequest(method, params: .object(values)))
    }

    @Test func sharedProfileVerificationPropagatesAndProfileChangesInvalidateOnlyOnePair() async throws {
        let fixture = try fixture("shared-status")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let shared = fixture.root.appendingPathComponent("shared profile")
        let changed = fixture.root.appendingPathComponent("changed profile")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        let first = SetupAgentPair(kind: .codex, executable: "/bin/sh", choice: .existing, destinationPath: shared.path)
        let second = SetupAgentPair(kind: .codex, executable: "/bin/sh", choice: .existing, destinationPath: shared.path)
        let draft = SetupDraft(teams: [
            SetupTeam(name: "Personal", agents: [first]),
            SetupTeam(name: "Work", agents: [second])
        ])
        let initial = try await save(draft, using: fixture.coordinator)

        let statusValue = try await call("verifySetupAuthentication", draftID: draft.id, pairID: first.id, using: fixture.coordinator)
        let status = try statusValue.decode(SetupAuthStatus.self)
        #expect(status.phase == .connected)
        var verified = try #require(try await fixture.store.setupDraft())
        #expect(verified.value.teams.flatMap(\.agents).allSatisfy { $0.auth.phase == .connected })

        var edited = verified.value
        edited.teams[1].agents[0].destinationPath = changed.path
        let changedDraft = try await save(edited, version: verified.version, using: fixture.coordinator)
        #expect(changedDraft.value.teams[0].agents[0].auth.phase == .connected)
        #expect(changedDraft.value.teams[1].agents[0].auth.phase == .notChecked)

        verified.value.dismissed = true
        await #expect(throws: ChauffeurError.self) {
            _ = try await save(verified.value, version: initial.version, using: fixture.coordinator)
        }
    }

    @Test func loginCreatesNoSessionAndFinishIsIdempotentWithStablePairPreset() async throws {
        let fixture = try fixture("finish")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = fixture.root.appendingPathComponent("existing profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        _ = try await fixture.store.save(BaseAgentPreset(name: "Codex Fixture", kind: .codex, executable: "/bin/sh"))
        _ = try await fixture.store.save(BaseAgentPreset(name: "Claude Fixture", kind: .claude, executable: "/bin/cat"))
        let pair = SetupAgentPair(kind: .codex, executable: "/bin/sh", choice: .existing, destinationPath: profile.path)
        let team = SetupTeam(name: "Work", agents: [pair])
        let draft = SetupDraft(teams: [team], defaultTeamID: team.id)
        _ = try await save(draft, using: fixture.coordinator)

        _ = try await call("startSetupLogin", draftID: draft.id, pairID: pair.id, using: fixture.coordinator)
        var connected: Stored<SetupDraft>?
        for _ in 0..<100 {
            let current = try await fixture.store.setupDraft()
            if current?.value.teams[0].agents[0].auth.phase == .connected { connected = current; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let ready = try #require(connected)
        #expect((await fixture.store.reload()).sessions.isEmpty)

        let firstIDs = try await call("finishSetup", draftID: draft.id, version: ready.version, using: fixture.coordinator).decode([UUID].self)
        #expect(firstIDs == [team.id])
        var finished = try #require(try await fixture.store.setupDraft())
        #expect(finished.value.completed)
        let firstSnapshot = await fixture.store.reload()
        #expect(firstSnapshot.presetSets.filter { $0.value.id == team.id }.count == 1)
        #expect(firstSnapshot.presets.filter { $0.value.id == pair.id && $0.value.setID == team.id }.count == 1)
        #expect(firstSnapshot.sessions.isEmpty)

        _ = try await call("finishSetup", draftID: draft.id, version: finished.version, using: fixture.coordinator)
        finished = try #require(try await fixture.store.setupDraft())
        let retriedSnapshot = await fixture.store.reload()
        #expect(retriedSnapshot.presetSets.filter { $0.value.id == team.id }.count == 1)
        #expect(retriedSnapshot.presets.filter { $0.value.id == pair.id }.count == 1)

        let replacement = SetupDraft()
        await #expect(throws: ChauffeurError.self) {
            _ = try await save(replacement, version: ready.version, using: fixture.coordinator)
        }
        let replaced = try await save(replacement, version: finished.version, using: fixture.coordinator)
        #expect(replaced.value.id == replacement.id)
    }

    @Test func selectingTheFullActiveCatalogUsesAllBaseWithoutCustomPresets() async throws {
        let fixture = try fixture("all-base")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let codexProfile = fixture.root.appendingPathComponent("codex profile")
        let claudeProfile = fixture.root.appendingPathComponent("claude profile")
        try FileManager.default.createDirectory(at: codexProfile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProfile, withIntermediateDirectories: true)
        _ = try await fixture.store.save(BaseAgentPreset(name: "Codex Fixture", kind: .codex, executable: "/bin/sh"))
        _ = try await fixture.store.save(BaseAgentPreset(name: "Claude Fixture", kind: .claude, executable: "/bin/cat"))
        let codex = SetupAgentPair(
            kind: .codex, executable: "/bin/sh", choice: .existing, destinationPath: codexProfile.path,
            auth: SetupAuthStatus(phase: .connected)
        )
        let claude = SetupAgentPair(
            kind: .claude, executable: "/bin/cat", choice: .existing, destinationPath: claudeProfile.path,
            auth: SetupAuthStatus(phase: .connected)
        )
        let team = SetupTeam(name: "Everything", agents: [codex, claude])
        let saved = try await save(SetupDraft(teams: [team]), using: fixture.coordinator)

        _ = try await call("finishSetup", draftID: saved.value.id, version: saved.version, using: fixture.coordinator)

        let snapshot = await fixture.store.reload()
        let storedTeam = try #require(snapshot.presetSets.first { $0.value.id == team.id })
        #expect(storedTeam.value.agentSelection == .allBase)
        #expect(snapshot.presets.allSatisfy { $0.value.setID != team.id })
        #expect(storedTeam.value.configurationDirectories?[CLIKind.codex.rawValue] == Paths.canonical(codexProfile.path))
        #expect(storedTeam.value.configurationDirectories?[CLIKind.claude.rawValue] == Paths.canonical(claudeProfile.path))
    }

    @Test func existingTeamWithoutJournalVersionConflictsAndPreservesExternalSettings() async throws {
        let fixture = try fixture("untracked-existing-team")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let externalProfile = fixture.root.appendingPathComponent("external profile")
        let wizardProfile = fixture.root.appendingPathComponent("wizard profile")
        try FileManager.default.createDirectory(at: externalProfile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wizardProfile, withIntermediateDirectories: true)
        var external = PresetSet(name: "External Name", agentSelection: .custom)
        external.configurationDirectories = [CLIKind.codex.rawValue: externalProfile.path]
        let storedExternal = try await fixture.store.save(external)
        let pair = SetupAgentPair(kind: .codex, executable: "/bin/sh", choice: .existing, destinationPath: wizardProfile.path)
        let draftTeam = SetupTeam(id: external.id, name: "Wizard Name", agents: [pair])
        let draft = try await save(SetupDraft(teams: [draftTeam]), using: fixture.coordinator)

        do {
            _ = try await call("finishSetup", draftID: draft.value.id, version: draft.version, using: fixture.coordinator)
            Issue.record("Expected an unjournaled existing team to conflict")
        } catch let error as ChauffeurError {
            #expect(error.code == "edit_conflict")
        }

        let snapshot = await fixture.store.reload()
        let preserved = try #require(snapshot.presetSets.first { $0.value.id == external.id })
        #expect(preserved.value.name == storedExternal.value.name)
        #expect(preserved.value.configurationDirectories == storedExternal.value.configurationDirectories)
        #expect(preserved.version == storedExternal.version)
    }

    @Test func recoverAcceptsExactPendingTeamWriteThenRejectsALaterExternalEdit() async throws {
        let fixture = try fixture("pending-team-version")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let profile = fixture.root.appendingPathComponent("recovered profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let pair = SetupAgentPair(kind: .codex, executable: "/bin/sh", choice: .existing, destinationPath: profile.path)
        var expected = PresetSet(name: "Recovered Team", agentSelection: .custom)
        expected.configurationDirectories = [CLIKind.codex.rawValue: Paths.canonical(profile.path)]
        expected.customAgentsInitialized = true
        var draftTeam = SetupTeam(id: expected.id, name: expected.name, agents: [pair])
        draftTeam.pendingVersion = JSONCoding.digest(try JSONCoding.encode(expected))
        _ = try await save(SetupDraft(teams: [draftTeam]), using: fixture.coordinator)
        let actual = try await fixture.store.save(expected)
        #expect(actual.version == draftTeam.pendingVersion)

        try await fixture.coordinator.recover()

        var recovered = try #require(try await fixture.store.setupDraft())
        #expect(recovered.value.teams[0].savedVersion == actual.version)
        #expect(recovered.value.teams[0].pendingVersion == nil)
        var externallyEdited = actual.value
        externallyEdited.name = "Externally Renamed"
        let external = try await fixture.store.save(externallyEdited, expectedVersion: actual.version)

        do {
            _ = try await call("finishSetup", draftID: recovered.value.id, version: recovered.version, using: fixture.coordinator)
            Issue.record("Expected a post-recovery external edit to conflict")
        } catch let error as ChauffeurError {
            #expect(error.code == "edit_conflict")
        }
        recovered = try #require(try await fixture.store.setupDraft())
        #expect(recovered.value.teams[0].savedVersion == actual.version)
        let snapshot = await fixture.store.reload()
        let preserved = try #require(snapshot.presetSets.first { $0.value.id == expected.id })
        #expect(preserved.value.name == "Externally Renamed")
        #expect(preserved.version == external.version)
    }

    @Test func emptyCatalogMixedTeamsRemainCustomToTheirSelectedAgent() async throws {
        let fixture = try fixture("mixed-catalog")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let codexProfile = fixture.root.appendingPathComponent("codex only")
        let claudeProfile = fixture.root.appendingPathComponent("claude only")
        try FileManager.default.createDirectory(at: codexProfile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProfile, withIntermediateDirectories: true)
        let codex = SetupAgentPair(kind: .codex, executable: "/bin/sh", choice: .existing, destinationPath: codexProfile.path)
        let claude = SetupAgentPair(kind: .claude, executable: "/bin/cat", choice: .existing, destinationPath: claudeProfile.path)
        let codexTeam = SetupTeam(name: "Codex Only", agents: [codex])
        let claudeTeam = SetupTeam(name: "Claude Only", agents: [claude])
        let saved = try await save(SetupDraft(teams: [codexTeam, claudeTeam]), using: fixture.coordinator)

        _ = try await call("finishSetup", draftID: saved.value.id, version: saved.version, using: fixture.coordinator)

        let snapshot = await fixture.store.reload()
        let storedCodex = try #require(snapshot.presetSets.first { $0.value.id == codexTeam.id })
        let storedClaude = try #require(snapshot.presetSets.first { $0.value.id == claudeTeam.id })
        #expect(storedCodex.value.agentSelection == .custom)
        #expect(storedClaude.value.agentSelection == .custom)
        #expect(snapshot.agents(in: storedCodex.value).map(\.kind) == [.codex])
        #expect(snapshot.agents(in: storedClaude.value).map(\.kind) == [.claude])
        #expect(snapshot.presets.contains { $0.value.id == codex.id && $0.value.setID == codexTeam.id })
        #expect(snapshot.presets.contains { $0.value.id == claude.id && $0.value.setID == claudeTeam.id })
    }

    @Test func recoverReconcilesAPublishedOperationBeforeResume() async throws {
        let fixture = try fixture("recover")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("created profile")
        let pair = SetupAgentPair(
            kind: .codex,
            executable: "/bin/sh",
            choice: .create,
            sourcePath: nil,
            destinationPath: destination.path
        )
        let draft = SetupDraft(teams: [SetupTeam(name: "Recovered", agents: [pair])])
        var saved = try await save(draft, using: fixture.coordinator)

        let previewValue = try await call("previewSetupCopy", draftID: draft.id, pairID: pair.id, version: saved.version, using: fixture.coordinator)
        let preview = try previewValue.decode(CopyPreview.self)
        saved = try #require(try await fixture.store.setupDraft())
        _ = try await call(
            "createSetupConfiguration",
            draftID: draft.id,
            pairID: pair.id,
            version: saved.version,
            extra: ["previewID": .string(preview.id.uuidString)],
            using: fixture.coordinator
        )
        saved = try #require(try await fixture.store.setupDraft())
        let operationID = try #require(saved.value.teams[0].agents[0].operationID)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("settings.toml").path))

        // Simulate the crash window after publication but before the draft recorded it.
        saved.value.teams[0].agents[0].operationID = nil
        saved.value.teams[0].agents[0].auth = SetupAuthStatus(phase: .connected)
        _ = try await fixture.store.saveSetupDraft(saved.value, expectedVersion: saved.version)
        let resumed = try OnboardingCoordinator(
            store: fixture.store,
            root: fixture.root.appendingPathComponent("store"),
            environment: ["HOME": fixture.home.path, "PATH": "/usr/bin:/bin"],
            home: fixture.home,
            authentication: [.codex: CoordinatorFakeAuthentication()],
            migrations: [.codex: CoordinatorFakeMigration()]
        )

        try await resumed.recover()

        let recovered = try #require(try await fixture.store.setupDraft())
        #expect(recovered.value.teams[0].agents[0].operationID == operationID)
        #expect(recovered.value.teams[0].agents[0].auth.phase == .notChecked)
        #expect(recovered.value.teams[0].agents[0].auth.message?.contains("Recheck") == true)
        #expect(try await fixture.store.setupOperations().first { $0.value.id == operationID }?.value.phase == .published)
    }
}
