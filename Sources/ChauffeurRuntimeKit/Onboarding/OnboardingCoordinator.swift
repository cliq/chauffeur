import Foundation
import ChauffeurCore

/// The single owner of setup side effects. Draft edits use optimistic versions;
/// long operations exclude other writes while reads remain available.
public actor OnboardingCoordinator {
    public let loginHost: SetupLoginHost
    let store: FileStore
    let environment: [String: String]
    let home: URL
    let workingDirectory: URL
    let publisher: ConfigurationPublisher
    let migrations: [CLIKind: any ConfigurationMigration]
    let authentication: [CLIKind: any AgentAuthentication]
    var previews: [UUID: CopyPreview] = [:]
    var mutating = false
    var activeLogin: (operationID: UUID, pairID: UUID, draftID: UUID)?
    var loginTask: Task<Void, Never>?

    public init(store: FileStore, root: URL, environment: [String: String], home: URL? = nil,
                loginHost: SetupLoginHost = SetupLoginHost(),
                authentication: [CLIKind: any AgentAuthentication] = [.codex: CodexAuthentication(), .claude: ClaudeAuthentication(), .opencode: OpenCodeAuthentication()],
                migrations: [CLIKind: any ConfigurationMigration] = [.codex: CodexConfigurationMigration(), .claude: ClaudeConfigurationMigration(), .opencode: OpenCodeConfigurationMigration()]) throws {
        self.store = store; self.environment = environment
        self.home = home ?? URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path)
        self.workingDirectory = root.appendingPathComponent("onboarding/login")
        self.loginHost = loginHost; self.authentication = authentication; self.migrations = migrations
        self.publisher = ConfigurationPublisher(store: store, migrations: migrations)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    public func recover() async throws {
        guard var saved = try await store.setupDraft(), !saved.value.completed else { return }
        for operation in try await store.setupOperations() where operation.value.draftID == saved.value.id {
            if let recovered = try? await publisher.recover(operation: operation.value), [.published, .teamSaved].contains(recovered.phase) {
                updatePair(&saved.value, id: recovered.pairID) { pair in pair.operationID = recovered.id; pair.destinationPath = recovered.destinationPath }
            }
        }
        for team in saved.value.teams {
            for pair in team.agents {
                if [.signingIn, .verifying].contains(pair.auth.phase) {
                    updatePair(&saved.value, id: pair.id) { $0.auth = SetupAuthStatus(phase: .signInRequired, message: "Sign-in was interrupted. Retry when you're ready.") }
                } else if pair.auth.phase == .connected {
                    updatePair(&saved.value, id: pair.id) { $0.auth = SetupAuthStatus(message: "Recheck this configuration after restarting the service.") }
                }
            }
        }
        let snapshot = await store.reload()
        for i in saved.value.teams.indices {
            let team = saved.value.teams[i]
            if let pending = team.pendingVersion, let actual = snapshot.presetSets.first(where: { $0.value.id == team.id }), actual.version == pending {
                saved.value.teams[i].savedVersion = actual.version
                saved.value.teams[i].pendingVersion = nil
            }
        }
        _ = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
    }

    public func refreshTeamVersions() async throws {
        guard var saved = try await store.setupDraft() else { return }
        let snapshot = await store.reload()
        for i in saved.value.teams.indices where saved.value.teams[i].savedVersion != nil {
            saved.value.teams[i].savedVersion = snapshot.presetSets.first { $0.value.id == saved.value.teams[i].id }?.version
        }
        _ = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
    }

    func inventory() async throws -> SetupInventory {
        let snapshot = await store.reload()
        var paths: [String: [String]] = [:]
        for team in snapshot.presetSets {
            for kind in CLIKind.allCases where kind.isAgent { paths[kind.rawValue, default: []].append(team.value.configurationDirectory(for: kind, home: home.path)) }
        }
        return try ConfigurationDiscovery(home: home, environment: environment, configuredPaths: paths).inventory()
    }

    func requireDraft(_ params: JSONValue, versioned: Bool = true) async throws -> Stored<SetupDraft> {
        let draftID = try params.uuid("draftID")
        guard let saved = try await store.setupDraft(), saved.value.id == draftID else {
            throw ChauffeurError("setup_missing", "This setup is no longer active. Reload setup.")
        }
        if versioned, saved.version != params["expectedVersion"].string { throw ChauffeurError("edit_conflict", "Setup changed in another window. Reload before continuing.") }
        return saved
    }

    func pair(in draft: SetupDraft, id: UUID) throws -> SetupAgentPair {
        guard let pair = draft.teams.flatMap(\.agents).first(where: { $0.id == id }) else { throw ChauffeurError("setup_pair_missing", "This agent was removed from setup.") }
        return pair
    }

    func updatePair(_ draft: inout SetupDraft, id: UUID, _ edit: (inout SetupAgentPair) -> Void) {
        for i in draft.teams.indices {
            if let j = draft.teams[i].agents.firstIndex(where: { $0.id == id }) { edit(&draft.teams[i].agents[j]); return }
        }
    }

    private func sameExecutable(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let resolved = try? Paths.executable(lhs, environment: environment) else { return false }
        return resolved == (try? Paths.executable(rhs, environment: environment))
    }

    private func canRepairExecutable(_ old: SetupAgentPair, with updated: SetupAgentPair) -> Bool {
        guard activeLogin == nil, (try? Paths.executable(old.executable, environment: environment)) == nil else { return false }
        let detected = environment["CHAUFFEUR_\(old.kind.rawValue.uppercased())_EXECUTABLE"] ?? old.kind.rawValue
        return sameExecutable(updated.executable, detected)
            && (try? Paths.executable(detected, environment: environment)) != nil
    }

    func saveDraft(_ params: JSONValue) async throws -> Stored<SetupDraft> {
        var draft = try params["record"].decode(SetupDraft.self)
        let prior = try await store.setupDraft()
        if let prior, prior.value.id != draft.id, !prior.value.completed { throw ChauffeurError("setup_exists", "Resume or finish the existing setup first.") }
        if let prior, prior.value.id == draft.id {
            for oldTeam in prior.value.teams {
                if oldTeam.savedVersion != nil || oldTeam.agents.contains(where: { $0.operationID != nil }) {
                    guard draft.teams.contains(where: { $0.id == oldTeam.id }) else { throw ChauffeurError("setup_saved_team", "A created team cannot be removed by discarding setup. Manage it in Settings.") }
                }
                for old in oldTeam.agents {
                    let updated = draft.teams.flatMap(\.agents).first { $0.id == old.id }
                    if old.operationID != nil || activeLogin?.pairID == old.id {
                        guard let updated, Paths.canonical(updated.destinationPath) == Paths.canonical(old.destinationPath),
                              updated.kind == old.kind,
                              sameExecutable(updated.executable, old.executable) || canRepairExecutable(old, with: updated) else {
                            throw ChauffeurError("setup_in_use", "This configuration is already created or signing in. Keep its folder and executable unchanged.")
                        }
                    }
                    guard let updated else { continue }
                    let configChanged = Paths.canonical(updated.destinationPath) != Paths.canonical(old.destinationPath) || !sameExecutable(updated.executable, old.executable) || updated.kind != old.kind
                    let copyChanged = configChanged || updated.sourcePath != old.sourcePath || updated.categories != old.categories || updated.projectPaths != old.projectPaths
                    updatePair(&draft, id: old.id) { value in
                        value.operationID = old.operationID
                        value.auth = configChanged ? SetupAuthStatus() : old.auth
                        value.previewID = copyChanged ? nil : old.previewID
                    }
                }
                if let index = draft.teams.firstIndex(where: { $0.id == oldTeam.id }) {
                    draft.teams[index].savedVersion = oldTeam.savedVersion
                    draft.teams[index].pendingVersion = oldTeam.pendingVersion
                }
            }
        }
        return try await store.saveSetupDraft(draft, expectedVersion: params["expectedVersion"].string)
    }

    func preview(_ params: JSONValue) async throws -> CopyPreview {
        var saved = try await requireDraft(params)
        let pair = try pair(in: saved.value, id: params.uuid("pairID"))
        guard pair.choice == .create, pair.operationID == nil, let adapter = migrations[pair.kind] else { throw ChauffeurError("setup_copy", "Choose a new configuration to preview.") }
        let reserved = saved.value.teams.flatMap(\.agents).filter { $0.id != pair.id && $0.choice == .create }.map(\.destinationPath)
        _ = try ConfigurationDiscovery(home: home, environment: environment, configuredPaths: [:]).validateDestination(source: pair.sourcePath, destination: pair.destinationPath, reserved: reserved)
        let preview = try adapter.preview(pair: pair)
        previews[preview.id] = preview
        updatePair(&saved.value, id: pair.id) { $0.previewID = preview.id }
        _ = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
        return preview
    }

    func createConfiguration(_ params: JSONValue) async throws -> CopyReceipt {
        var saved = try await requireDraft(params)
        let pair = try pair(in: saved.value, id: params.uuid("pairID"))
        let previewID = try params.uuid("previewID")
        guard pair.previewID == previewID, let preview = previews[previewID], preview.pairID == pair.id else { throw ChauffeurError("setup_preview_expired", "Preview this configuration again before copying.") }
        let operations = try await store.setupOperations()
        var operation = operations.first { $0.value.draftID == saved.value.id && $0.value.pairID == pair.id }?.value
            ?? SetupOperation(draftID: saved.value.id, pairID: pair.id, destinationPath: pair.destinationPath, previewID: preview.id)
        if operation.previewID != preview.id, ![.published, .teamSaved].contains(operation.phase) {
            try await publisher.discardStaging(operation: operation)
            operation.previewID = preview.id; operation.stagingPath = nil
            operation.destinationPath = pair.destinationPath; operation.phase = .prepared
        }
        let receipt = try await publisher.publish(operation: operation, preview: preview, pair: pair)
        updatePair(&saved.value, id: pair.id) { $0.operationID = receipt.operationID; $0.destinationPath = receipt.destinationPath; $0.auth = SetupAuthStatus(phase: .signInRequired) }
        _ = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
        return receipt
    }

    func authContext(_ pair: SetupAgentPair) throws -> AuthenticationContext {
        let executable = try Paths.executable(pair.executable, environment: environment)
        let directory = try Paths.directory(pair.destinationPath)
        return AuthenticationContext(kind: pair.kind, executable: executable, configurationPath: directory,
            baseEnvironment: environment, workingDirectory: workingDirectory.path)
    }

    func applyStatus(_ status: SetupAuthStatus, pair source: SetupAgentPair, draftID: UUID) async throws {
        guard var saved = try await store.setupDraft(), saved.value.id == draftID else { return }
        for pair in saved.value.teams.flatMap(\.agents) where pair.kind == source.kind && sameExecutable(pair.executable, source.executable) && Paths.canonical(pair.destinationPath) == Paths.canonical(source.destinationPath) {
            updatePair(&saved.value, id: pair.id) { $0.auth = status }
        }
        _ = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
    }

    func verify(_ params: JSONValue) async throws -> SetupAuthStatus {
        let saved = try await requireDraft(params, versioned: false)
        let pair = try pair(in: saved.value, id: params.uuid("pairID"))
        guard activeLogin == nil else { throw ChauffeurError("setup_login_busy", "Finish or cancel the current sign-in first.") }
        let status: SetupAuthStatus
        do {
            let context = try authContext(pair)
            guard let adapter = authentication[pair.kind] else { throw ChauffeurError("setup_agent", "Agent not supported.") }
            status = await adapter.status(context: context)
        } catch { status = SetupAuthStatus(phase: .unableToVerify, checkedAt: Date(), message: "Check the executable and configuration folder, then retry. \(error.localizedDescription)") }
        try await applyStatus(status, pair: pair, draftID: saved.value.id)
        return status
    }

    func startLogin(_ params: JSONValue) async throws -> SetupLoginHandle {
        let saved = try await requireDraft(params, versioned: false)
        let pair = try pair(in: saved.value, id: params.uuid("pairID"))
        if let activeLogin {
            if activeLogin.pairID == pair.id, let handle = await loginHost.status(operationID: activeLogin.operationID) { return handle }
            throw ChauffeurError("setup_login_busy", "Finish or cancel the current sign-in first.")
        }
        guard let adapter = authentication[pair.kind] else { throw ChauffeurError("setup_agent", "Agent not supported.") }
        let context = try authContext(pair)
        let command = try await adapter.loginCommand(context: context)
        let operationID = UUID()
        let handle = try await loginHost.start(operationID: operationID, command: command)
        activeLogin = (operationID, pair.id, saved.value.id)
        try await applyStatus(SetupAuthStatus(phase: .signingIn), pair: pair, draftID: saved.value.id)
        loginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let code = try await self.loginHost.waitForExit(operationID: operationID)
                await self.loginEnded(operationID: operationID, pair: pair, draftID: saved.value.id, exitCode: code)
            } catch { await self.loginEnded(operationID: operationID, pair: pair, draftID: saved.value.id, exitCode: -1) }
        }
        return handle
    }

    func loginEnded(operationID: UUID, pair: SetupAgentPair, draftID: UUID, exitCode: Int32) async {
        guard activeLogin?.operationID == operationID else { return }
        // Wait for a short draft write/copy operation, not for UI attachment.
        while mutating { try? await Task.sleep(for: .milliseconds(50)) }
        guard activeLogin?.operationID == operationID else { return }
        mutating = true
        defer { mutating = false; activeLogin = nil; loginTask = nil }
        do {
            if exitCode != 0 {
                try await applyStatus(SetupAuthStatus(phase: .failed, message: "Sign-in did not finish. Retry when you're ready."), pair: pair, draftID: draftID)
                return
            }
            try await applyStatus(SetupAuthStatus(phase: .verifying), pair: pair, draftID: draftID)
            let context = try authContext(pair)
            let status = await authentication[pair.kind]?.status(context: context) ?? SetupAuthStatus(phase: .unableToVerify)
            try await applyStatus(status, pair: pair, draftID: draftID)
        } catch { /* Existing persisted state is rechecked on resume; never log terminal output. */ }
    }

    func cancelLogin(_ params: JSONValue) async throws {
        let id = try params.uuid("operationID")
        guard let active = activeLogin, active.operationID == id else { return }
        activeLogin = nil; loginTask?.cancel(); loginTask = nil
        try await loginHost.cancel(operationID: id)
        if let saved = try await store.setupDraft(), let pair = try? pair(in: saved.value, id: active.pairID) {
            try await applyStatus(SetupAuthStatus(phase: .signInRequired, message: "Sign-in cancelled. You can retry later."), pair: pair, draftID: active.draftID)
        }
    }

    func finish(_ params: JSONValue) async throws -> [UUID] {
        var saved = try await requireDraft(params)
        var ids: [UUID] = []
        // Validate the entire draft before saving any presets or teams. A typo
        // must not make Finish silently omit a requested agent or team.
        guard !saved.value.teams.isEmpty else { throw ChauffeurError("setup_no_ready_teams", "Add at least one team before finishing setup.") }
        for team in saved.value.teams {
            try Validation.name(team.name)
            guard !team.agents.isEmpty else { throw ChauffeurError("setup_team_unavailable", "\(team.name): select at least one installed agent before finishing setup.") }
            for pair in team.agents {
                do { _ = try Paths.directory(pair.destinationPath) }
                catch {
                    let remedy = pair.operationID == nil ? "Go back and choose an existing folder." : "Restore the created folder at its original location before finishing setup."
                    throw ChauffeurError("setup_configuration_unavailable", "\(team.name) · \(pair.kind.displayName): the configuration folder is missing or unavailable. \(remedy)", path: pair.destinationPath)
                }
                do { _ = try Paths.executable(pair.executable, environment: environment) }
                catch { throw ChauffeurError("setup_executable_unavailable", "\(team.name) · \(pair.kind.displayName): the agent is no longer installed at this location. Go back to the first step and recheck installed agents.", path: pair.executable) }
            }
        }
        // Resolve the complete catalog before deciding whether any team should
        // inherit all presets; later teams must not expand an earlier subset.
        for pair in saved.value.teams.flatMap(\.agents) {
            let snapshot = await store.reload()
            // Equivalent binaries are not equivalent persistent references: an
            // old base may point directly at a version target that will vanish.
            if !snapshot.baseAgentPresets.contains(where: { $0.value.kind == pair.kind && !$0.value.archived && $0.value.executable == pair.executable }) {
                _ = try await store.save(BaseAgentPreset(name: pair.kind.displayName, kind: pair.kind, executable: pair.executable))
            }
        }
        for index in saved.value.teams.indices {
            var team = saved.value.teams[index]
            try Validation.name(team.name)
            let available = team.agents
            var bases: [UUID: BaseAgentPreset] = [:]
            for pair in available {
                let latest = await store.reload()
                if let base = latest.baseAgentPresets.first(where: { $0.value.kind == pair.kind && !$0.value.archived && $0.value.executable == pair.executable }) {
                    bases[pair.id] = base.value
                } else {
                    bases[pair.id] = try await store.save(BaseAgentPreset(name: pair.kind.displayName, kind: pair.kind, executable: pair.executable)).value
                }
            }
            let snapshot = await store.reload()
            let existing = snapshot.presetSets.first { $0.value.id == team.id }
            if let existing, existing.version != team.savedVersion, existing.version != team.pendingVersion {
                throw ChauffeurError("edit_conflict", "\(team.name) changed outside this setup. Its settings were preserved. Manage it in Settings or discard this draft to start again.")
            }
            if existing == nil, team.savedVersion != nil { throw ChauffeurError("edit_conflict", "\(team.name) was removed outside this setup. It will not be recreated automatically.") }
            var record = existing?.value ?? PresetSet(name: team.name, agentSelection: .custom)
            record.id = team.id; record.name = team.name
            record.configurationDirectories = Dictionary(uniqueKeysWithValues: available.map { ($0.kind.rawValue, Paths.canonical($0.destinationPath)) })
            let selectedBases = Set(bases.values.map(\.id))
            let allBases = Set(snapshot.baseAgentPresets.filter { !$0.value.archived }.map { $0.value.id })
            record.agentSelection = selectedBases == allBases ? .allBase : .custom
            record.isDefault = snapshot.presetSets.isEmpty || saved.value.defaultTeamID == team.id
            // FileStore normalizes these fields. Persist the exact expected hash
            // before the write so recovery can distinguish our result from edits.
            if record.agentSelection == .custom { record.customAgentsInitialized = true }
            if let existing {
                let old = existing.value
                let changed = old.name != record.name || old.archived != record.archived || old.isDefault != record.isDefault || old.agentSelection != record.agentSelection || old.configurationDirectories != record.configurationDirectories
                record.revision = old.revision + (changed ? 1 : 0)
            }
            team.pendingVersion = JSONCoding.digest(try JSONCoding.encode(record))
            saved.value.teams[index] = team
            saved = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
            var storedTeam = try await store.save(record, expectedVersion: existing?.version)
            team.savedVersion = storedTeam.version; team.pendingVersion = nil
            saved.value.teams[index] = team
            saved = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
            for pair in available {
                let latest = await store.reload()
                if storedTeam.value.agentSelection == .custom, let baseValue = bases[pair.id] {
                    // Pair UUID is allocated in the draft before any write, so retries are idempotent.
                    var preset = baseValue.agent(in: storedTeam.value, copy: true); preset.id = pair.id
                    let oldPreset = latest.presets.first { $0.value.id == pair.id }
                    var expectedParent = storedTeam.value
                    if oldPreset?.value != preset { expectedParent.revision += 1 }
                    team.pendingVersion = JSONCoding.digest(try JSONCoding.encode(expectedParent))
                    saved.value.teams[index] = team
                    saved = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
                    _ = try await store.save(preset, expectedVersion: oldPreset?.version)
                    storedTeam = await store.reload().presetSets.first { $0.value.id == team.id } ?? storedTeam
                    team.savedVersion = storedTeam.version; team.pendingVersion = nil
                    saved.value.teams[index] = team
                    saved = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
                }
                if let opID = pair.operationID, let operation = try await store.setupOperations().first(where: { $0.value.id == opID }) {
                    var finished = operation.value; finished.phase = .teamSaved
                    _ = try await store.saveSetupOperation(finished, expectedVersion: operation.version)
                }
            }
            team.savedVersion = storedTeam.version; saved.value.teams[index] = team; ids.append(team.id)
            saved = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
        }
        guard !ids.isEmpty else { throw ChauffeurError("setup_no_ready_teams", "Choose an installed executable and an existing configuration folder for at least one team.") }
        saved.value.completed = saved.value.teams.allSatisfy { team in ids.contains(team.id) && team.agents.allSatisfy { $0.auth.phase == .connected } }
        saved.value.dismissed = true
        _ = try await store.saveSetupDraft(saved.value, expectedVersion: saved.version)
        return ids
    }
}
