import ChauffeurCore
import Foundation
import Testing
@testable import ChauffeurRuntimeKit

struct DefaultTeamRuntimeTests {
    private func makeRuntime(root: URL) throws -> RuntimeCoordinator {
        try RuntimeCoordinator(root: root, ctlPath: "/bin/false", environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": root.path])
    }

    private func sets(_ runtime: RuntimeCoordinator) async -> [PresetSet] {
        await runtime.store.refresh().presetSets.map(\.value).sorted { $0.name < $1.name }
    }

    @Test func startupFlagsTheFirstTeamByNameWhenNoneIsDefault() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-default-team-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeRuntime(root: root)
        try await runtime.store.save(PresetSet(name: "Zeta"))
        try await runtime.store.save(PresetSet(name: "Alpha"))
        try await runtime.start()
        let after = await sets(runtime)
        #expect(after.map(\.isDefault) == [true, false])
    }

    @Test func savingADefaultTeamClearsThePreviousOneAndDeletionPromotesAnother() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-default-team-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeRuntime(root: root)
        try await runtime.start()
        var alpha = PresetSet(name: "Alpha"); alpha.isDefault = true
        _ = try await runtime.handle(IPCRequest("savePresetSet", params: .object(["record": try .from(alpha)])))
        var beta = PresetSet(name: "Beta"); beta.isDefault = true
        let savedBeta = try await runtime.handle(IPCRequest("savePresetSet", params: .object(["record": try .from(beta)]))).decode(Stored<PresetSet>.self)
        #expect(savedBeta.value.isDefault)
        var after = await sets(runtime)
        #expect(after.map { "\($0.name):\($0.isDefault)" } == ["Alpha:false", "Beta:true"])

        let betaVersion = await runtime.store.refresh().presetSets.first { $0.value.id == beta.id }!.version
        _ = try await runtime.handle(IPCRequest("deletePresetSet", params: .object(["setID": .string(beta.id.uuidString), "version": .string(betaVersion)])))
        after = await sets(runtime)
        #expect(after.map { "\($0.name):\($0.isDefault)" } == ["Alpha:true"])
    }

    @Test func projectSavedWithAnUnknownTeamGetsTheDefault() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-default-team-\(UUID())").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try makeRuntime(root: root)
        let team = PresetSet(name: "Only")
        try await runtime.store.save(team)
        try await runtime.start()
        let project = Project(name: "Fresh", presetSetID: UUID())
        let saved = try await runtime.handle(IPCRequest("saveProject", params: .object(["record": try .from(project)]))).decode(Stored<Project>.self)
        #expect(saved.value.presetSetID == team.id)
    }
}
