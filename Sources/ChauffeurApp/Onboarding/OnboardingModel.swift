import SwiftUI
import ChauffeurCore

@MainActor final class OnboardingModel: ObservableObject {
    @Published var draft = SetupDraft()
    @Published var inventory: SetupInventory?
    @Published var previews: [UUID: CopyPreview] = [:]
    @Published var executables: [String: String] = [:]
    @Published var busy = false
    @Published var loaded = false
    @Published var error: String?
    @Published var login: SetupLoginHandle?
    @Published var loginPairID: UUID?
    private(set) var version: String?
    private var app: AppModel?
    private var saveTask: Task<Void, Never>?
    private var saving: Task<Void, Error>?
    private var pollTask: Task<Void, Never>?
    var home: String { inventory?.homePath ?? FileManager.default.homeDirectoryForCurrentUser.path }
    var pairs: [SetupAgentPair] { draft.teams.flatMap(\.agents) }
    var selectedKinds: [CLIKind] { CLIKind.allCases.filter { $0.isAgent && draft.accountCounts[$0.rawValue] != nil } }

    func load(app: AppModel) async {
        guard !loaded else { return }
        self.app = app
        await perform {
            self.inventory = try await app.call("setupInventory").decode(SetupInventory.self)
            self.executables = self.inventory?.executables ?? [:]
            let stored = try await app.call("setupDraft").decode(Optional<Stored<SetupDraft>>.self)
            if let stored, !stored.value.completed {
                self.draft = stored.value; self.version = stored.version
                self.executables.merge(stored.value.executables) { _, saved in saved }
                for pair in self.pairs { self.executables[pair.kind.rawValue] = pair.executable }
            } else {
                self.draft = SetupDraft()
                for kind in CLIKind.allCases where kind.isAgent && self.executables[kind.rawValue] != nil {
                    self.draft.accountCounts[kind.rawValue] = .single
                }
                self.version = stored?.version
            }
            let active = try await app.call("activeSetupLogin")
            if let pairID = active["pairID"].string.flatMap(UUID.init(uuidString:)) {
                self.login = try active["handle"].decode(SetupLoginHandle.self)
                self.loginPairID = pairID; self.draft.step = .login
            }
            self.loaded = true
        }
        if loaded { startPolling() }
    }

    func scheduleSave() {
        guard loaded, !busy else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)); try Task.checkCancellation(); try await self?.save() }
            catch is CancellationError {} catch { self?.error = error.localizedDescription }
        }
    }

    func save() async throws {
        if let saving { try await saving.value }
        guard let app else { return }
        draft.executables = executables
        let value = draft
        let expected = version
        let task = Task { @MainActor in
            let saved = try await app.call("saveSetupDraft", .object([
                "record": try .from(value), "expectedVersion": expected.map(JSONValue.string) ?? .null
            ])).decode(Stored<SetupDraft>.self)
            self.version = saved.version
        }
        saving = task
        defer { saving = nil }
        try await task.value
    }

    func reload() async throws {
        guard let app, let stored = try await app.call("setupDraft").decode(Optional<Stored<SetupDraft>>.self) else { return }
        draft = stored.value; version = stored.version
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !busy else { return }
        saveTask?.cancel(); busy = true; error = nil
        defer { busy = false }
        do { if let saving { try await saving.value }; try await action() }
        catch { self.error = error.localizedDescription }
    }

    func addTeam(name: String = "") {
        var team = SetupTeam(name: name)
        team.agents = selectedKinds.map { newPair(kind: $0, teamName: name) }
        draft.teams.append(team)
        if draft.defaultTeamID == nil { draft.defaultTeamID = team.id }
    }

    func newPair(kind: CLIKind, teamName: String) -> SetupAgentPair {
        let current = inventory?.configurations.first { $0.kind == kind && $0.isCurrent }?.path
            ?? "\(home)/.\(kind == .claude ? "claude" : "codex")"
        return SetupAgentPair(kind: kind, executable: executables[kind.rawValue] ?? kind.rawValue,
            choice: .current, sourcePath: "\(home)/.\(kind == .claude ? "claude" : "codex")", destinationPath: current)
    }

    func suggestedDestination(kind: CLIKind, name: String) -> String {
        "\(home)/.\(kind == .claude ? "claude" : "codex")-\(Paths.slug(name))"
    }

    func currentPath(_ kind: CLIKind) -> String {
        inventory?.configurations.first { $0.kind == kind && $0.isCurrent }?.path
            ?? "\(home)/.\(kind == .claude ? "claude" : "codex")"
    }

    func next() async {
        await perform {
            switch self.draft.step {
            case .agents:
                guard !self.selectedKinds.isEmpty else { throw ChauffeurError("setup_agents", "Choose at least one agent.") }
                if self.draft.teams.isEmpty { self.addTeam(name: "Personal") }
                for i in self.draft.teams.indices {
                    self.draft.teams[i].agents.removeAll { !self.selectedKinds.contains($0.kind) }
                    for kind in self.selectedKinds where !self.draft.teams[i].agents.contains(where: { $0.kind == kind }) {
                        self.draft.teams[i].agents.append(self.newPair(kind: kind, teamName: self.draft.teams[i].name))
                    }
                    for j in self.draft.teams[i].agents.indices {
                        let kind = self.draft.teams[i].agents[j].kind
                        self.draft.teams[i].agents[j].executable = self.executables[kind.rawValue] ?? kind.rawValue
                    }
                }
                self.draft.step = .teams
            case .teams:
                guard !self.draft.teams.isEmpty, self.draft.teams.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.agents.isEmpty }) else {
                    throw ChauffeurError("setup_teams", "Give every team a name and select at least one agent.")
                }
                self.draft.step = .configurations
            case .configurations:
                self.draft.step = self.pairs.contains(where: { $0.choice == .create && $0.operationID == nil }) ? .copy : .login
            case .copy:
                try await self.save()
                let creating = self.pairs.filter { $0.choice == .create && $0.operationID == nil }
                for pair in creating {
                    guard let preview = self.previews[pair.id] else { throw ChauffeurError("setup_preview", "Preview the settings for every new folder before creating it.") }
                    _ = try await self.call("createSetupConfiguration", pairID: pair.id, extras: ["previewID": .string(preview.id.uuidString)])
                    try await self.reload()
                }
                self.draft.step = .login
            case .login: self.draft.step = .summary
            case .summary: break
            }
            try await self.save()
            if self.draft.step == .login { try await self.checkAll() }
        }
    }

    func back() {
        let steps: [SetupStep] = [.agents, .teams, .configurations, .copy, .login, .summary]
        if let index = steps.firstIndex(of: draft.step), index > 0 { draft.step = steps[index - 1] }
    }

    func preview(_ id: UUID) async {
        await perform {
            try await self.save()
            self.previews[id] = try await self.call("previewSetupCopy", pairID: id).decode(CopyPreview.self)
            try await self.reload()
        }
    }

    func call(_ method: String, pairID: UUID? = nil, extras: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard let app else { throw ChauffeurError("setup_unavailable", "Reconnect to the service.") }
        var params = extras
        params["draftID"] = .string(draft.id.uuidString)
        params["expectedVersion"] = version.map(JSONValue.string) ?? .null
        if let pairID { params["pairID"] = .string(pairID.uuidString) }
        return try await app.call(method, .object(params))
    }

    private func checkAll() async throws {
        var checked = Set<String>()
        for pair in pairs where ![.signingIn, .verifying].contains(pair.auth.phase) {
            let context = "\(pair.kind.rawValue)\n\(pair.executable)\n\(Paths.canonical(pair.destinationPath))"
            guard checked.insert(context).inserted else { continue }
            _ = try await call("verifySetupAuthentication", pairID: pair.id)
            try await reload()
        }
        // Newly created profiles proceed directly into their first sign-in.
        if let pair = pairs.first(where: { $0.choice == .create && $0.auth.phase == .signInRequired }) {
            login = try await call("startSetupLogin", pairID: pair.id).decode(SetupLoginHandle.self)
            loginPairID = pair.id
            try await reload()
        }
    }

    func signIn(_ id: UUID) async {
        await perform {
            try await self.save()
            self.login = try await self.call("startSetupLogin", pairID: id).decode(SetupLoginHandle.self)
            self.loginPairID = id
            try await self.reload()
        }
    }

    func verify(_ id: UUID) async {
        await perform { _ = try await self.call("verifySetupAuthentication", pairID: id); try await self.reload() }
    }

    func cancelLogin() async {
        guard let login else { return }
        await perform {
            _ = try await self.call("cancelSetupLogin", extras: ["operationID": .string(login.operationID.uuidString)])
            self.login = nil; self.loginPairID = nil
            try await self.reload()
        }
    }

    func finish() async -> UUID? {
        var selected: UUID?
        await perform {
            try await self.save()
            let ids = try await self.call("finishSetup", extras: ["defaultTeamID": self.draft.defaultTeamID.map { .string($0.uuidString) } ?? .null]).decode([UUID].self)
            selected = self.draft.defaultTeamID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            try await self.reload()
            try await self.app?.refresh()
        }
        return selected
    }

    func finishLater() async -> Bool {
        await perform { self.draft.dismissed = true; try await self.save() }
        return error == nil
    }

    func discard() async -> Bool {
        await perform {
            _ = try await self.call("discardSetup")
        }
        return error == nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                guard !self.busy, self.draft.step == .login, self.pairs.contains(where: { [.signingIn, .verifying].contains($0.auth.phase) }) else { continue }
                do { try await self.reload() } catch { self.error = error.localizedDescription }
            }
        }
    }

    func stopObserving() { pollTask?.cancel(); saveTask?.cancel() }
}
