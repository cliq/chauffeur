import Foundation
import ChauffeurCore

extension OnboardingCoordinator {
    /// Previewing an Add Team form never persists or resumes the onboarding draft.
    func previewTeamConfiguration(_ params: JSONValue) throws -> CopyPreview {
        let pair = try params["pair"].decode(SetupAgentPair.self)
        guard pair.choice == .create, let adapter = migrations[pair.kind] else {
            throw ChauffeurError("team_copy", "Choose a new configuration folder to preview.")
        }
        _ = try ConfigurationDiscovery(home: home, environment: environment, configuredPaths: [:])
            .validateDestination(source: pair.sourcePath, destination: pair.destinationPath, reserved: [])
        let preview = try adapter.preview(pair: pair)
        return preview
    }

    /// Add one team, using the same migrations and publication journal as onboarding.
    /// The form owns its IDs; retries can reuse folders published by this submission.
    func addTeam(_ params: JSONValue) async throws -> Stored<PresetSet> {
        let team = try params["record"].decode(PresetSet.self)
        let pairs = try params["configurations"].decode([SetupAgentPair].self)
        try team.validate()
        guard !(await store.reload()).presetSets.contains(where: { $0.value.id == team.id }) else {
            throw ChauffeurError("team_exists", "This team has already been saved. Close this dialog and edit it in Settings.")
        }
        guard Set(pairs.map(\.kind)).count == pairs.count, Set(pairs.map(\.id)).count == pairs.count else {
            throw ChauffeurError("team_copy", "Choose only one configuration per agent.")
        }
        let operations = try await store.setupOperations()
        var copies: [(SetupAgentPair, CopyPreview, SetupOperation)] = []
        let discovery = ConfigurationDiscovery(home: home, environment: environment, configuredPaths: [:])
        // Check every selection before publishing any folder.
        for pair in pairs {
            guard pair.choice == .create, migrations[pair.kind] != nil,
                  let path = team.configurationDirectories?[pair.kind.rawValue],
                  Paths.canonical(path) == Paths.canonical(pair.destinationPath) else {
                throw ChauffeurError("team_copy", "Choose a matching new configuration folder for each agent.")
            }
            let supplied = operations.first { $0.value.draftID == team.id && $0.value.pairID == pair.id }?.value
                ?? SetupOperation(draftID: team.id, pairID: pair.id, destinationPath: pair.destinationPath)
            if !FileManager.default.fileExists(atPath: pair.destinationPath) {
                _ = try discovery.validateDestination(source: pair.sourcePath, destination: pair.destinationPath,
                    reserved: pairs.filter { $0.id != pair.id }.map(\.destinationPath))
            }
            let (operation, preview) = try await publisher.prepare(operation: supplied, pair: pair)
            copies.append((pair, preview, operation))
        }
        for (pair, preview, operation) in copies {
            _ = try await publisher.publish(operation: operation, preview: preview, pair: pair)
        }
        return try await store.save(team)
    }
}
