import ChauffeurCore
import Foundation
import Testing
@testable import ChauffeurRuntimeKit

private struct ExecutableProbeAuthentication: AgentAuthentication {
    func loginCommand(context: AuthenticationContext) async throws -> SetupCommand {
        SetupCommand(executable: context.executable, arguments: [], directory: context.workingDirectory, environment: context.baseEnvironment)
    }
    func status(context: AuthenticationContext) async -> SetupAuthStatus {
        SetupAuthStatus(phase: .connected, method: context.executable)
    }
}

struct OnboardingReviewRegressionTests {
    private struct Fixture {
        let root: URL
        let store: FileStore
        let coordinator: OnboardingCoordinator
        let environment: [String: String]
        let command: URL
        let oldBinary: URL
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-review-\(UUID())")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let old = root.appendingPathComponent("codex-v1")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: old)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old.path)
        let command = bin.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: command, withDestinationURL: old)
        let environment = ["HOME": root.path, "PATH": bin.path + ":/usr/bin:/bin"]
        let store = try FileStore(root: root.appendingPathComponent("store"))
        let coordinator = try OnboardingCoordinator(store: store, root: root.appendingPathComponent("store"), environment: environment, home: root,
            authentication: [.codex: ExecutableProbeAuthentication()])
        return Fixture(root: root, store: store, coordinator: coordinator, environment: environment, command: command, oldBinary: old)
    }

    private func save(_ draft: SetupDraft, version: String? = nil, _ f: Fixture) async throws -> Stored<SetupDraft> {
        try await f.coordinator.handle(IPCRequest("saveSetupDraft", params: .object([
            "record": try .from(draft), "expectedVersion": version.map(JSONValue.string) ?? .null
        ]))).decode(Stored<SetupDraft>.self)
    }

    private func call(_ method: String, pair: SetupAgentPair? = nil, extra: [String: JSONValue] = [:], _ f: Fixture) async throws -> JSONValue {
        let draft = try #require(try await f.store.setupDraft())
        var params: [String: JSONValue] = ["draftID": .string(draft.value.id.uuidString), "expectedVersion": .string(draft.version)]
        if let pair { params["pairID"] = .string(pair.id.uuidString) }
        params.merge(extra) { _, new in new }
        return try await f.coordinator.handle(IPCRequest(method, params: .object(params)))
    }

    private func createdPair(executable: String, _ f: Fixture) async throws -> SetupAgentPair {
        let pair = SetupAgentPair(kind: .codex, executable: executable, choice: .create, destinationPath: f.root.appendingPathComponent(".codex-work").path)
        _ = try await save(SetupDraft(executables: ["codex": executable], teams: [SetupTeam(name: "Work", agents: [pair])]), f)
        let preview = try await call("previewSetupCopy", pair: pair, f).decode(CopyPreview.self)
        _ = try await call("createSetupConfiguration", pair: pair, extra: ["previewID": .string(preview.id.uuidString)], f)
        return pair
    }

    private func updateBinary(_ f: Fixture) throws -> URL {
        let next = f.root.appendingPathComponent("codex-v2")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: next)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: next.path)
        try FileManager.default.removeItem(at: f.command)
        try FileManager.default.createSymbolicLink(at: f.command, withDestinationURL: next)
        try FileManager.default.removeItem(at: f.oldBinary)
        return next
    }

    @Test func discoveryPreservesCommandAndExplicitSymlink() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(try ConfigurationDiscovery(home: f.root, environment: f.environment, configuredPaths: [:]).inventory().executables["codex"] == "codex")
        var env = f.environment; env["CHAUFFEUR_CODEX_EXECUTABLE"] = f.command.path
        #expect(try ConfigurationDiscovery(home: f.root, environment: env, configuredPaths: [:]).inventory().executables["codex"] == f.command.path)
    }

    @Test func createdConfigurationSurvivesBinaryUpdateAndSavesStablePreset() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pair = try await createdPair(executable: "codex", f)
        let next = try updateBinary(f)
        let auth = try await call("verifySetupAuthentication", pair: pair, f).decode(SetupAuthStatus.self)
        #expect(auth.phase == .connected)
        #expect(auth.method == Paths.canonical(next.path))
        let ids = try await call("finishSetup", f).decode([UUID].self)
        #expect(ids.count == 1)
        let bases = await f.store.reload().baseAgentPresets.filter { $0.value.kind == .codex }
        #expect(!bases.isEmpty)
        #expect(bases.allSatisfy { $0.value.executable == "codex" })
    }

    @Test func finishDoesNotInheritARealpathFromAnExistingBasePreset() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.store.save(BaseAgentPreset(name: "Pre-update Codex", kind: .codex, executable: Paths.canonical(f.oldBinary.path)))
        let pair = try await createdPair(executable: "codex", f)
        _ = try await call("finishSetup", f)
        let selected = try #require(await f.store.reload().presets.first { $0.value.id == pair.id })
        #expect(selected.value.executable == "codex")
        let next = try updateBinary(f)
        #expect(try Paths.executable(selected.value.executable, environment: f.environment) == Paths.canonical(next.path))
    }

    @Test func legacyCreatedDraftCanRepairVanishedVersionedExecutable() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await createdPair(executable: Paths.canonical(f.oldBinary.path), f)
        _ = try updateBinary(f)
        let old = try #require(try await f.store.setupDraft())
        var repair = old.value
        repair.executables["codex"] = "codex"
        repair.teams[0].agents[0].executable = "codex"
        let saved = try await save(repair, version: old.version, f)
        #expect(saved.value.teams[0].agents[0].operationID == old.value.teams[0].agents[0].operationID)
        #expect(try await call("finishSetup", f).decode([UUID].self).count == 1)
    }

    @Test func finishRejectsMissingAgentOrFolderBeforeSavingAnyTeam() async throws {
        for missingExecutable in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let good = SetupAgentPair(kind: .codex, executable: "codex", choice: .existing, destinationPath: f.root.path)
            let bad = SetupAgentPair(kind: .codex, executable: missingExecutable ? "/missing-agent" : "codex", choice: .existing,
                destinationPath: missingExecutable ? f.root.path : f.root.appendingPathComponent("typo").path)
            let saved = try await save(SetupDraft(teams: [SetupTeam(name: "Valid", agents: [good]), SetupTeam(name: "Broken", agents: [bad])]), f)
            let before = await f.store.reload()
            do {
                _ = try await call("finishSetup", f)
                Issue.record("Finish must reject an unavailable configuration")
            } catch let error as ChauffeurError {
                #expect(error.code == (missingExecutable ? "setup_executable_unavailable" : "setup_configuration_unavailable"))
                #expect(error.localizedDescription.contains("Broken"))
            }
            let after = await f.store.reload()
            #expect(after.presetSets.count == before.presetSets.count)
            #expect(after.baseAgentPresets.count == before.baseAgentPresets.count)
            #expect(try await f.store.setupDraft()?.version == saved.version)
        }
    }
}
