import Foundation
import ChauffeurCore

public actor RuntimeCoordinator {
    public let id: UUID
    public let store: FileStore
    public let ledger: Ledger
    public let terminals: TmuxHost
    public let worktrees: WorktreeManager
    public let snapshots: SnapshotStore
    public let root: URL
    private let identity: RuntimeIdentity?
    private let ctlPath: String
    private let baseEnvironment: [String: String]
    private var sessions: [UUID: Session] = [:]
    private var launching = Set<UUID>()
    private var launchTasks: [UUID: Task<Session, Error>] = [:]
    private var stopRequests = Set<UUID>()
    private var stopGenerations: [UUID: UInt64] = [:]
    private var stopping = Set<UUID>()
    private var stoppingAllSessions = false
    private var reconciliation: Task<Void, Error>?
    private var checkoutClaims = CheckoutClaims()
    private var endpoint: String?
    private var settings = RetentionSettings()
    private var recentErrors: [ChauffeurError] = []
    private let logs: RuntimeLogStore?
    private var metadataErrors: [ChauffeurError] = []
    private var repositoryInventories: [RepositoryInventory] = []
    private var worktreeScan: Task<Void, Never>?
    private var worktreeRecordWrites = Set<UUID>()
    private var worktreeCreations: [UUID: (String, Task<Stored<Worktree>, Error>)] = [:]
    private struct WorktreeRegistration: Hashable { let projectID: UUID; let folderID: UUID; let path: String }
    private var worktreeRegistrations: [WorktreeRegistration: Task<Stored<Worktree>, Error>] = [:]
    private var captures: [UUID: Task<TerminalSnapshot?, Error>] = [:]
    private var maintaining = false
    private var retentionSettingsPending = false
    private var lastMessageCleanup = Date.distantPast
    private var snapshotStorage = SnapshotStorageStatus(budgetBytes: RetentionSettings().snapshotBudgetBytes)
    private var skillInstaller: SkillInstaller?
    private let onboarding: OnboardingCoordinator
    private var notificationAuthorization = NotificationAuthorization.unknown
    private var notificationHeartbeat: Date?
    private var notificationHelperAvailable = false
    private var notificationCleanupPending = false
    private var remoteAccess: RemoteAccessService?
    public func attachRemoteAccess(_ service: RemoteAccessService) { remoteAccess = service }
    private func remoteAccessService() throws -> RemoteAccessService {
        guard let remoteAccess else { throw ChauffeurError("remote_access_unavailable", "Remote access is not available in this runtime") }
        return remoteAccess
    }
    public func configureNotifications(available: Bool) { notificationHelperAvailable = available }
    public func shouldLaunchNotificationHelper() async throws -> Bool {
        let enabled = try await ledger.notificationsEnabled()
        return notificationHelperAvailable && (enabled || notificationCleanupPending)
    }
    private func notificationStatus() async throws -> NotificationStatus {
        NotificationStatus(enabled: try await ledger.notificationsEnabled(),
                           authorization: notificationHelperAvailable ? notificationAuthorization : .unavailable,
                           helperConnected: notificationHeartbeat.map { Date().timeIntervalSince($0) < 15 } ?? false)
    }
    /// `worktreeRoot` is where new managed checkouts are created; `nil` keeps
    /// them under the data root, as fixtures and earlier releases do. When it
    /// is set, checkouts under the data root remain managed.
    public init(root: URL, worktreeRoot: URL? = nil, ctlPath: String, environment: [String: String], logs: RuntimeLogStore? = nil, id: UUID = UUID(), identity: RuntimeIdentity? = nil, sessionsApp: URL? = nil) throws {
        self.id = id
        self.identity = identity
        self.logs = logs ?? (try? RuntimeLogStore(root: RuntimeLogStore.directory(for: root)))
        self.root = root; self.ctlPath = ctlPath; self.baseEnvironment = environment
        store = try FileStore(root: root)
        ledger = try Ledger(path: root.appendingPathComponent("runtime/ledger.sqlite").path)
        terminals = try TmuxHost(runtimeDirectory: root.appendingPathComponent("runtime"), ctlPath: ctlPath, environment: environment, sessionsApp: sessionsApp)
        let legacyWorktreeRoot = root.appendingPathComponent("worktrees")
        worktrees = WorktreeManager(root: worktreeRoot ?? legacyWorktreeRoot, legacyRoots: worktreeRoot == nil ? [] : [legacyWorktreeRoot])
        snapshots = try SnapshotStore(root: root.appendingPathComponent("runtime/snapshots"))
        onboarding = try OnboardingCoordinator(store: store, root: root, environment: environment)
    }
    public func start() async throws {
        logs?.append(RuntimeLogEntry(.runtimeStarting, runtimeID: id))
        try await store.migrateTeamAgents()
        let snapshot = await store.reload()
        try await normalizeDefaultTeam()
        try await onboarding.recover()
        // The ledger preserves accepted membership and orphaned live sessions
        // even if a project directory was removed while the service was running.
        let recorded = try await ledger.allSessions()
        for item in recorded { sessions[item.id] = item }
        for record in snapshot.sessions {
            if let existing = sessions[record.value.id], existing.projectID != record.value.projectID || existing.groupID != record.value.groupID {
                self.record(ChauffeurError("immutable_membership", "Session file changes its recorded membership; restore its original IDs", path: record.path))
                continue
            }
            sessions[record.value.id] = record.value
            try await ledger.register(record.value)
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")) {
            do { let loaded = try JSONCoding.decode(RetentionSettings.self, from: data); try loaded.validate(); settings = loaded }
            catch { record(ChauffeurError("invalid_settings", "Cannot load retention settings", path: root.appendingPathComponent("settings.json").path)) }
        }
        try await reconcile(startup: true)
        await maintainHistory(applySettings: true)
        for var delegation in try await ledger.allDelegations() where [.reserved, .launching].contains(delegation.state) {
            if let child = sessions[delegation.childID], child.state.isLive { delegation.state = .running }
            else { delegation.state = .interrupted; delegation.error = "Runtime stopped during launch. Inspect the retained worktree and explicitly retry" }
            try await ledger.updateDelegation(delegation)
        }
    }
    public func setEndpoint(port: Int) {
        endpoint = "http://127.0.0.1:\(port)/mcp"
        logs?.append(RuntimeLogEntry(.runtimeReady, runtimeID: id))
    }
    public func health() -> JSONValue {
        .object(["runtimeID": .string(id.uuidString), "version": .string(RuntimeVersion.current), "protocolVersion": .number(Double(WireProtocol.major)), "mcpEndpoint": endpoint.map(JSONValue.string) ?? .null, "liveSessions": .number(Double(sessions.values.filter { $0.state.isLive }.count)), "status": .string("running"), "identity": identity.flatMap { try? .from($0) } ?? .null, "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))])
    }
    public func snapshot() async throws -> JSONValue {
        let snapshot = await store.refresh()
        var object: [String: JSONValue] = ["store": try .from(snapshot), "sessions": try .from(Array(sessions.values).sorted { $0.createdAt < $1.createdAt }), "messages": try .from(await ledger.allMessages()), "delegations": try .from(await ledger.allDelegations()), "health": health(), "settings": try .from(settings), "notifications": try .from(await notificationStatus()), "snapshotStorage": try .from(snapshotStorage), "errors": try .from(recentErrors), "repositoryInventories": try .from(repositoryInventories)]
        if let remoteAccess { object["remoteAccess"] = try .from(await remoteAccess.status()) }
        return .object(object)
    }
    public func reconcileWorktrees() async {
        if let pending = worktreeScan { await pending.value; return }
        let pending = Task { await self.scanWorktrees() }
        worktreeScan = pending
        await pending.value
        worktreeScan = nil
    }
    /// Scans after any in-flight scan finishes, so a folder registered while a
    /// scan was already running is still observed promptly.
    private func rescanWorktrees() {
        Task {
            while let pending = worktreeScan { await pending.value; await Task.yield() }
            await reconcileWorktrees()
        }
    }
    private func scanWorktrees() async {
        let snapshot = await store.refresh()
        let records = snapshot.worktrees.filter { $0.value.registered }
        var seenSources = Set<String>()
        let sources = (snapshot.projects.flatMap { $0.value.folders.filter(\.registered).map(\.canonicalPath) }.sorted()
            + records.map { $0.value.repositoryPath }.sorted() + records.map { $0.value.path }.sorted()).filter { seenSources.insert($0).inserted }
        var observations: [RepositoryInventory] = []
        var repositories: [UUID: RepositoryInventory] = [:]
        for path in sources {
            if Task.isCancelled { return }
            let result = await worktrees.observe(at: path, cached: repositories)
            if result.status == .available, let id = result.repositoryID {
                if let index = observations.firstIndex(where: { $0.status == .available && $0.repositoryID == id }) {
                    observations[index].sourcePaths?.append(path)
                } else {
                    var grouped = result; grouped.sourcePaths = [path]
                    observations.append(grouped); repositories[id] = grouped
                }
            } else { observations.append(result) }
        }
        let recordedBases = Dictionary(records.map { (Paths.canonical($0.value.path), $0.value.baseBranch) }, uniquingKeysWith: { first, _ in first })
        for index in observations.indices where observations[index].status == .available {
            if Task.isCancelled { return }
            observations[index].entries = await worktrees.annotated(observations[index].entries) { recordedBases[$0.path] ?? nil }
        }
        for stored in records {
            let observed = repositories[stored.value.repositoryID]
                ?? observations.first { observation in
                    stored.value.repositoryIdentityVersion == nil && observation.status == .available
                        && (observation.legacyRepositoryID == stored.value.repositoryID
                            || stored.value.gitIdentity.map { identity in observation.entries.contains { $0.gitIdentity == identity } } == true)
                }
                ?? observations.first { $0.sourcePath == stored.value.repositoryPath }
                ?? RepositoryInventory(sourcePath: stored.value.repositoryPath, status: .failed)
            let updated = await worktrees.reconciled(stored.value, inventory: observed)
            if observed.status == .available, updated.availability == .missing, !worktreeRecordWrites.contains(updated.id),
               !checkoutClaims.isRemoving(path: updated.path, worktreeID: updated.id),
               sessionsUsing(path: updated.path, worktreeIDs: [updated.id], folderID: updated.folderID, in: knownSessions(snapshot)).isEmpty {
                // Nothing refers to this checkout any more, so the record has no purpose.
                do { try await store.delete(worktree: updated.id) }
                catch let error as ChauffeurError { record(error) }
                catch { record(ChauffeurError("worktree_unavailable", "Stale worktree record could not be removed", path: updated.path)) }
                continue
            }
            guard updated != stored.value else { continue }
            do { try await saveWorktree(updated, expectedVersion: stored.version) }
            catch let error as ChauffeurError where error.code == "edit_conflict" || error.code == "worktree_busy" { /* Next scan uses the new record; never overwrite an external edit or removal. */ }
            catch let error as ChauffeurError { record(error) }
            catch { record(ChauffeurError("worktree_unavailable", "Worktree reconciliation could not save a record")) }
        }
        repositoryInventories = observations
    }
    @discardableResult private func saveWorktree(_ value: Worktree, expectedVersion: String? = nil, finishingRemoval: Bool = false) async throws -> Stored<Worktree> {
        guard !worktreeRecordWrites.contains(value.id), finishingRemoval || !checkoutClaims.isRemoving(path: value.path, worktreeID: value.id) else {
            throw ChauffeurError("worktree_busy", "Worktree metadata is being updated. Retry after the operation finishes", path: value.path)
        }
        worktreeRecordWrites.insert(value.id); defer { worktreeRecordWrites.remove(value.id) }
        return try await store.save(value, expectedVersion: expectedVersion)
    }
    private func persist(_ session: Session, notification: AttentionReason? = nil) async throws {
        let previous = sessions[session.id]
        let reason = notification ?? (session.state == .failed && previous?.state != .failed ? .failure : nil)
        try await ledger.register(session, notification: reason)
        if previous == nil || previous?.state != session.state || previous?.processID != session.processID || previous?.runtimeID != session.runtimeID || previous?.failureCode != session.failureCode {
            var entry = RuntimeLogEntry(.sessionChanged, runtimeID: id)
            entry.sessionID = session.id; entry.projectID = session.projectID; entry.groupID = session.groupID
            entry.state = session.state; entry.processID = session.processID; entry.exitStatus = session.exitStatus
            entry.code = session.failureCode.map { .redacting($0) }
            logs?.append(entry)
        }
        sessions[session.id] = session
        let snapshot = await store.current()
        guard snapshot.projects.contains(where: { $0.value.id == session.projectID }) else { return }
        do { try await store.save(session, expectedVersion: snapshot.sessions.first { $0.value.id == session.id }?.version) }
        catch let error as ChauffeurError { record(error) }
    }
    public func record(_ error: ChauffeurError) {
        recentErrors.append(error); if recentErrors.count > 100 { recentErrors.removeFirst(recentErrors.count - 100) }
        var entry = RuntimeLogEntry(.operationFailed, runtimeID: id); entry.code = .redacting(error.code)
        logs?.append(entry)
    }
    public func diagnostics() async -> DiagnosticsReport {
        let snapshot = await store.refresh()
        let logReport = logs?.recent() ?? DiagnosticLogs(status: .unavailable)
        let logErrors = logReport.status == .unavailable ? [ChauffeurError("log_unavailable", "Structured logs are unavailable")] : []
        return DiagnosticsReport(sessions: Array(sessions.values), health: health(), errors: snapshot.errors + repositoryInventories.compactMap(\.error) + recentErrors + logErrors, observation: .live, observedAt: Date(), logs: logReport)
    }
    private var liveSessionIDs: Set<UUID> { Set(sessions.values.filter { $0.state.isLive }.map(\.id)) }
    private func captureHistory(_ sessionID: UUID) async throws -> TerminalSnapshot? {
        if let pending = captures[sessionID] { return try await pending.value }
        guard let session = sessions[sessionID], !launching.contains(sessionID) else { return try await snapshots.read(sessionID) }
        // Share in-flight work so a history request cannot return an absent or
        // stale archive while periodic capture is still producing its result.
        let pending = Task<TerminalSnapshot?, Error> { try await self.captureAndSaveHistory(session) }
        captures[sessionID] = pending
        defer { captures.removeValue(forKey: sessionID) }
        return try await pending.value
    }
    private func captureAndSaveHistory(_ session: Session) async throws -> TerminalSnapshot {
        let sessionID = session.id
        let value = try await terminals.capture(sessionID: sessionID, lines: settings.scrollbackLines)
        guard session.processID == value.processID, session.terminalIdentity == value.terminalIdentity,
              sessions[sessionID]?.processID == value.processID, sessions[sessionID]?.terminalIdentity == value.terminalIdentity,
              !launching.contains(sessionID) else { throw ChauffeurError("snapshot_unavailable", "Terminal ownership changed while saving history") }
        let saved = try await snapshots.save(value, settings: settings, liveSessions: liveSessionIDs)
        snapshotStorage = try await snapshots.status(budgetBytes: settings.snapshotBudgetBytes)
        return saved
    }
    public func maintainHistory(applySettings: Bool = false) async {
        if applySettings { retentionSettingsPending = true }
        guard !maintaining else { return }
        maintaining = true; defer { maintaining = false }
        let applySettings = retentionSettingsPending
        retentionSettingsPending = false
        do {
            let inventory = try await terminals.inventory()
            for pane in inventory {
                guard let sessionID = UUID(uuidString: pane.sessionName), let session = sessions[sessionID],
                      session.processID == pane.processID, session.terminalIdentity == pane.paneID,
                      !launching.contains(sessionID), captures[sessionID] == nil else { continue }
                do {
                    if let saved = try await captureHistory(sessionID), pane.dead, sessions[sessionID]?.state.isLive == false { try await terminals.retireDead(saved) }
                } catch let error as ChauffeurError { record(error) }
                catch { record(ChauffeurError("snapshot_failed", "Could not save terminal history")) }
            }
            snapshotStorage = try await (applySettings ? snapshots.applyRetention(settings: settings, liveSessions: liveSessionIDs) : snapshots.prune(settings: settings, liveSessions: liveSessionIDs))
            if applySettings || Date().timeIntervalSince(lastMessageCleanup) >= 3600 {
                _ = try await ledger.pruneCompletedMessages(olderThan: Date().addingTimeInterval(-Double(settings.completedMessageDays) * 86400))
                lastMessageCleanup = Date()
            }
        } catch let error as ChauffeurError { record(error) }
        catch { record(ChauffeurError("retention_failed", "History cleanup could not finish")) }
    }
    public func reconcile(startup: Bool = false) async throws {
        if let reconciliation { try await reconciliation.value; return }
        let task = Task { try await self.performReconcile(startup: startup) }
        reconciliation = task
        defer { reconciliation = nil }
        try await task.value
    }
    private func performReconcile(startup: Bool) async throws {
        // Consume file notifications even while every UI is closed. With no
        // events this returns cached metadata without touching the filesystem.
        let metadata = await store.refresh()
        if metadata.errors != metadataErrors {
            metadataErrors = metadata.errors
            var entry = RuntimeLogEntry(.metadataInvalid, runtimeID: id); entry.count = metadata.errors.count
            logs?.append(entry)
        }
        let observed = Array(sessions.values)
        let inventory = try await terminals.inventory()
        for var session in observed where !launching.contains(session.id) && sessions[session.id] == session {
            let pane = inventory.first { $0.sessionName == session.id.uuidString }
            let sameOwner = pane != nil && (session.processID == nil || session.processID == pane?.processID) && (session.terminalIdentity == nil || session.terminalIdentity == pane?.paneID)
            if let pane, sameOwner {
                if pane.dead && session.state.isLive {
                    let stopped = stopping.remove(session.id) != nil
                    session.state = stopped ? .interrupted : (pane.exitStatus == 0 ? .exited : .failed)
                    session.error = stopped || pane.exitStatus == 0 ? nil : "CLI exited with status \(pane.exitStatus.map(String.init) ?? "unknown")"
                    session.exitStatus = pane.exitStatus
                    session.failureCode = stopped || pane.exitStatus == 0 ? nil : "cli_exit"
                    try await ledger.revoke(sessionID: session.id)
                    stopping.remove(session.id)
                } else if !pane.dead && startup {
                    session.state = .activityUnknown; session.runtimeID = id; session.processID = pane.processID; session.terminalIdentity = pane.paneID
                }
            } else if session.state.isLive {
                let stopped = stopping.remove(session.id) != nil
                session.state = .interrupted; session.error = stopped ? nil : "Terminal ownership was lost. Resume a recorded conversation explicitly"
                session.failureCode = stopped ? nil : "terminal_ownership_lost"
                try await ledger.revoke(sessionID: session.id)
            }
            if sessions[session.id] != session { session.updatedAt = Date(); try await persist(session) }
            // Natural successful exits follow the same retention policy as closing
            // a tab. Explicit stop/close requests own their cleanup; failures stay
            // available so the user can inspect what went wrong.
            if session.state == .exited, !settings.keepFinishedSessions,
               !stopRequests.contains(session.id) {
                try await deleteFinishedSession(session.id)
            }
        }
        let pending = try await ledger.allMessages().filter { [.queued, .received].contains($0.state) }
        for var session in Array(sessions.values) where !launching.contains(session.id) {
            let count = pending.filter { $0.recipientID == session.id }.count
            if session.pendingMessages != count { session.pendingMessages = count; try await persist(session) }
        }
    }
    public func handle(_ request: IPCRequest) async throws -> JSONValue {
        guard request.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "App and runtime protocol versions differ. Restart the background service") }
        if OnboardingCoordinator.methods.contains(request.method) {
            let result = try await onboarding.handle(request)
            if request.method == "finishSetup" {
                let preferred = (try? await store.setupDraft())?.value.defaultTeamID
                try await normalizeDefaultTeam(preferring: preferred)
                try await onboarding.refreshTeamVersions()
            }
            return result
        }
        let params = request.params
        switch request.method {
        case "hello", "version", "status": return health()
        case "snapshot": return try await snapshot()
        case "notificationStatus": return try .from(await notificationStatus())
        case "testNotification":
            let status = try await notificationStatus()
            guard status.enabled, status.helperConnected, [.authorized, .provisional].contains(status.authorization) else { throw ChauffeurError("notifications_unavailable", "Enable and allow session notifications, then wait for the notification helper to connect") }
            let sessionID = try params.uuid("sessionID")
            let snapshot = await store.refresh()
            guard let session = sessions[sessionID], snapshot.projects.contains(where: { $0.value.id == session.projectID && !$0.value.archived }) else { throw ChauffeurError("missing_session", "Select a session in an active project") }
            return try .from(await ledger.testNotification(sessionID: sessionID))
        case "setNotifications":
            guard let enabled = params["enabled"].bool else { throw ChauffeurError("invalid_argument", "enabled must be a boolean") }
            if enabled && !notificationHelperAvailable { throw ChauffeurError("notification_unavailable", "Notifications require Chauffeur's installed app and default background service") }
            let previous = try await ledger.notificationsEnabled()
            try await ledger.setNotificationsEnabled(enabled)
            if previous && !enabled { notificationCleanupPending = true }
            return try .from(await notificationStatus())
        case "notificationWork":
            let authorization = try params["authorization"].decode(NotificationAuthorization.self)
            notificationAuthorization = authorization; notificationHeartbeat = Date()
            let enabled = try await ledger.notificationsEnabled()
            if !enabled { notificationCleanupPending = false; return try .from(NotificationWork(enabled: false, deliveries: [])) }
            let snapshot = await store.refresh()
            var deliveries: [NotificationDelivery] = []
            for notice in try await ledger.pendingNotifications() {
                guard let session = sessions[notice.route.sessionID], session.projectID == notice.route.projectID,
                      let project = snapshot.projects.first(where: { $0.value.id == notice.route.projectID })?.value else {
                    try await ledger.acknowledgeNotification(notice.id); continue
                }
                deliveries.append(NotificationDelivery(notice: notice, project: project.name, session: session.title))
            }
            return try .from(NotificationWork(enabled: true, deliveries: deliveries))
        case "acknowledgeNotification":
            try await ledger.acknowledgeNotification(params.uuid("noticeID")); return .null
        case "diagnostics": return try .from(await diagnostics())
        case "skillDocument": return .string(String(decoding: try CoordinationSkill.bundled().document, as: UTF8.self))
        case "skillStatus", "installSkill", "removeSkill":
            let presetID = try params.uuid("presetID")
            let snapshot = await store.reload()
            let teamID = params["teamID"].string.flatMap(UUID.init(uuidString:))
                ?? snapshot.presets.first(where: { $0.value.id == presetID })?.value.setID
            guard let teamID, let preset = snapshot.agents(teamID: teamID).first(where: { $0.id == presetID }) else { throw ChauffeurError("missing_preset", "Choose an available agent and team") }
            if skillInstaller == nil { skillInstaller = SkillInstaller(skill: try CoordinationSkill.bundled()) }
            let installer = skillInstaller!
            if request.method == "skillStatus" { return try .from(await installer.status(directory: preset.configurationDirectory)) }
            let revision = try params.requiredString("revision")
            if request.method == "installSkill" { return try .from(await installer.install(directory: preset.configurationDirectory, revision: revision)) }
            return try .from(await installer.remove(directory: preset.configurationDirectory, revision: revision))
        case "sessionActivity":
            let sessionID = try params.uuid("sessionID")
            guard let session = sessions[sessionID] else { throw ChauffeurError("missing_session", "Session not found") }
            guard session.state.isLive, !launching.contains(sessionID) else { return try .from(TerminalActivity(idle: true, command: nil)) }
            let foreground = try await terminals.foregroundCommand(sessionID: sessionID)
            // An agent CLI is its own pane's foreground process, so only a shell
            // sitting at its prompt is idle. A shell that ran a nested shell in
            // the foreground reads as idle too; that is the cost of asking tmux.
            let shell = URL(fileURLWithPath: session.launch.executablePath).lastPathComponent
            let idle = foreground == nil || (!session.launch.preset.kind.isAgent && foreground == shell)
            return try .from(TerminalActivity(idle: idle, command: foreground))
        case "terminalSnapshot":
            let sessionID = try params.uuid("sessionID")
            guard sessions[sessionID] != nil else { throw ChauffeurError("missing_session", "Session not found") }
            // A disconnected or ended terminal can still expose its last archive.
            do { if let value = try await captureHistory(sessionID) { return try .from(value) } }
            catch let error as ChauffeurError where error.code == "snapshot_unavailable" || error.code == "terminal_inventory" || error.code == "terminal_missing" { }
            if let saved = try await snapshots.read(sessionID) { return try .from(saved) }
            throw ChauffeurError("snapshot_unavailable", "No saved terminal history is available for this session")
        case "deletePresetSet":
            try await store.deletePresetSet(params.uuid("setID"), expectedVersion: params.requiredString("version"))
            try await normalizeDefaultTeam()
            return .object(["deleted": .bool(true)])
        case "savePresetSet":
            var set = try params["record"].decode(PresetSet.self)
            if set.agentSelection == nil, !(await store.refresh()).presetSets.contains(where: { $0.value.id == set.id }) {
                set.agentSelection = .allBase; set.configurationDirectories = [:]
            }
            let saved = try await store.save(set, expectedVersion: params["version"].string)
            try await normalizeDefaultTeam(preferring: set.isDefault ? set.id : nil)
            return try .from(await store.refresh().presetSets.first { $0.value.id == set.id } ?? saved)
        case "saveBaseAgentPreset": return try .from(await store.save(params["record"].decode(BaseAgentPreset.self), expectedVersion: params["version"].string))
        case "savePreset": return try .from(await store.save(params["record"].decode(AgentPreset.self), expectedVersion: params["version"].string))
        case "saveProject":
            var project = try params["record"].decode(Project.self)
            // A project created without naming a team gets the default team.
            let known = await store.refresh()
            if !known.presetSets.contains(where: { $0.value.id == project.presetSetID }), let fallback = known.defaultPresetSet {
                project.presetSetID = fallback.id
            }
            let saved = try await store.save(project, expectedVersion: params["version"].string)
            // A new folder shows as loading in the app until it is observed; do not make it wait for the periodic tick.
            if project.folders.contains(where: { $0.registered && repositoryInventories.observation(for: $0.canonicalPath) == nil }) { rescanWorktrees() }
            return try .from(saved)
        case "saveWindow": return try .from(await store.save(params["record"].decode(WindowState.self), expectedVersion: params["version"].string))
        case "discoverFolders":
            let parent = try params.requiredString("path")
            return try .from(await Task.detached { RepositoryDiscovery.scan(parent: parent) }.value)
        case "launch": return try .from(await launch(params.decode(LaunchRequest.self)))
        case "resume": return try .from(await resume(params.uuid("sessionID")))
        case "interrupt": try await terminals.interrupt(sessionID: params.uuid("sessionID")); return .object(["sent": .bool(true)])
        case "deleteSession":
            let sessionID = try params.uuid("sessionID")
            guard stopRequests.insert(sessionID).inserted else { throw ChauffeurError("stop_pending", "Session cleanup is already in progress") }
            defer { stopRequests.remove(sessionID) }
            try await reconcile()
            try await deleteFinishedSession(sessionID)
            return .object(["deleted": .bool(true)])
        case "hasRunningSessionTerminals":
            return .bool(try await terminals.inventory().contains { !$0.dead })
        case "hasSessionTerminals":
            return .bool(try await !terminals.inventory().isEmpty)
        case "forceStopAllSessions":
            try await forceStopAllSessions()
            return .object(["stopped": .bool(true)])
        case "stop", "closeSession":
            let sessionID = try params.uuid("sessionID")
            guard sessions[sessionID] != nil || launchTasks[sessionID] != nil else { throw ChauffeurError("missing_session", "Session not found") }
            guard stopRequests.insert(sessionID).inserted else { throw ChauffeurError("stop_pending", "Stop is already in progress") }
            defer {
                stopRequests.remove(sessionID)
                if sessions[sessionID]?.state.isLive != true { stopping.remove(sessionID) }
            }
            let closing = request.method == "closeSession"
            let keepHistory = settings.keepFinishedSessions
            if closing && keepHistory { _ = try? await captureHistory(sessionID) }
            stopGenerations[sessionID, default: 0] += 1
            stopping.insert(sessionID)
            let launch = launchTasks[sessionID]
            launch?.cancel()
            try await ledger.revoke(sessionID: sessionID)
            // Wait for startup's cleanup before acknowledging Stop. A resume
            // cannot enter while either reservation is held.
            if let launch { _ = await launch.result }
            try await terminals.stop(sessionID: sessionID, force: closing || (params["force"].bool ?? false))
            try await reconcile()
            if closing {
                if keepHistory, var session = sessions[sessionID] {
                    session.unread = false
                    try await persist(session)
                } else { try await deleteFinishedSession(sessionID) }
            }
            return .object(["requested": .bool(true)])
        case "markRead":
            let sessionID = try params.uuid("sessionID")
            guard var session = sessions[sessionID] else { throw ChauffeurError("missing_session", "Session not found") }
            session.unread = false; try await persist(session); return .null
        case "event": return try await event(params)
        case "cancelMessage":
            let messageID = try params.uuid("messageID")
            guard let message = try await ledger.allMessages().first(where: { $0.id == messageID }) else { throw ChauffeurError("missing_message", "Message not found") }
            return try .from(await ledger.cancelMessage(messageID, caller: Caller(sessionID: message.senderID, scope: message.scope)))
        case "worktreeInventory": return try .from(await worktrees.inventory(at: params.requiredString("path")))
        case "refreshWorktrees": await reconcileWorktrees(); return try .from(repositoryInventories)
        case "previewWorktreeDeletion":
            return try await deleteWorktree(projectID: params.uuid("projectID"), folderID: params.uuid("folderID"), path: params.requiredString("path"), preview: true)
        case "deleteWorktree":
            let result = try await deleteWorktree(projectID: params.uuid("projectID"), folderID: params.uuid("folderID"), path: params.requiredString("path"), discardChanges: params["discardChanges"].bool == true)
            await reconcileWorktrees()
            return result
        case "pruneWorktrees":
            let snapshot = await store.current(), projectID = try params.uuid("projectID"), folderID = try params.uuid("folderID")
            guard let folder = snapshot.projects.first(where: { $0.value.id == projectID })?.value.folders.first(where: { $0.id == folderID && $0.registered }) else { throw ChauffeurError("missing_folder", "Select a registered project folder") }
            try await worktrees.prune(repositoryPath: folder.canonicalPath)
            await reconcileWorktrees()
            return try .from(repositoryInventories)
        case "previewWorktree":
            let snapshot = await store.current(), projectID = try params.uuid("projectID"), folderID = try params.uuid("folderID")
            guard let folder = snapshot.projects.first(where: { $0.value.id == projectID })?.value.folders.first(where: { $0.id == folderID && $0.registered }) else { throw ChauffeurError("missing_folder", "Select a registered repository") }
            return .object(["path": .string(try await worktrees.previewDestination(folder: folder, branch: params.requiredString("branch")).path)])
        case "registerWorktree":
            let key = WorktreeRegistration(projectID: try params.uuid("projectID"), folderID: try params.uuid("folderID"), path: Paths.canonical(try params.requiredString("path")))
            if let pending = worktreeRegistrations[key] { return try .from(await pending.value) }
            let pending = Task { try await self.registerWorktree(key) }
            worktreeRegistrations[key] = pending
            defer { worktreeRegistrations.removeValue(forKey: key) }
            return try .from(await pending.value)
        case "createWorktree":
            return try .from(await createWorktree(params.decode(WorktreeCreationRequest.self)))
        case "removeWorktree":
            let snapshot = await store.current(), worktreeID = try params.uuid("worktreeID")
            guard var stored = snapshot.worktrees.first(where: { $0.value.id == worktreeID }) else { throw ChauffeurError("missing_worktree", "Worktree not found") }
            guard !worktreeRecordWrites.contains(worktreeID) else { throw ChauffeurError("worktree_busy", "Worktree metadata is being updated. Retry removal") }
            if stored.value.managed {
                let relatedIDs = Set(snapshot.worktrees.filter { Paths.canonical($0.value.path) == Paths.canonical(stored.value.path) || (stored.value.gitIdentity != nil && $0.value.gitIdentity == stored.value.gitIdentity) }.map { $0.value.id })
                try checkoutClaims.beginRemoval(worktreeID, path: stored.value.path, worktreeIDs: relatedIDs, gitIdentity: stored.value.gitIdentity, sessions: Array(sessions.values))
                defer { checkoutClaims.endRemoval(worktreeID) }
                try await worktrees.remove(stored.value, liveSessions: Array(sessions.values))
                stored.value.registered = false
                return try .from(await saveWorktree(stored.value, expectedVersion: stored.version, finishingRemoval: true))
            }
            stored.value.registered = false; return try .from(await saveWorktree(stored.value, expectedVersion: stored.version))
        case "saveSettings":
            let value = try params.decode(RetentionSettings.self); try value.validate()
            try JSONCoding.encode(value).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
            settings = value
            // Cleanup errors remain visible through the normal runtime error list.
            await maintainHistory(applySettings: true)
            return try .from(value)
        case "reconcile": try await reconcile(); return health()
        case "remoteAccessStatus": return try .from(await remoteAccessService().status())
        case "setRemoteAccess":
            guard let enabled = params["enabled"].bool else { throw ChauffeurError("invalid_argument", "enabled must be a boolean") }
            return try .from(await remoteAccessService().setEnabled(enabled, port: params["port"].int))
        case "beginPairing": return try .from(await remoteAccessService().beginPairing())
        case "cancelPairing": return try .from(await remoteAccessService().cancelPairing())
        case "revokeRemoteDevice": return try .from(await remoteAccessService().revokeDevice(params.uuid("deviceID")))
        case "resetRemoteAccess": return try .from(await remoteAccessService().resetAccess())
        default: throw ChauffeurError("unknown_method", "Unknown runtime method")
        }
    }
    /// Stored session records plus live ones the store may not have saved yet.
    private func knownSessions(_ snapshot: StoreSnapshot) -> [Session] {
        var byID = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.value.id, $0.value) })
        for session in sessions.values { byID[session.id] = session }
        return Array(byID.values)
    }
    /// Sessions whose history belongs to a checkout: by worktree record, or by
    /// working directory for sessions launched before the record existed.
    private func sessionsUsing(path: String, worktreeIDs: Set<UUID>, folderID: UUID, in sessions: [Session]) -> [Session] {
        let canonical = Paths.canonical(path)
        return sessions.filter { session in
            session.folderID == folderID && (session.worktreeID.map(worktreeIDs.contains) == true
                || (session.worktreeID == nil && Paths.canonical(session.launch.workingDirectory) == canonical))
        }
    }
    private func deleteFinishedSession(_ sessionID: UUID) async throws {
        guard let session = sessions[sessionID] else { throw ChauffeurError("missing_session", "Session not found") }
        guard !session.state.isLive, !launching.contains(sessionID) else {
            throw ChauffeurError("active_session", "Stop the session before deleting its history")
        }
        // Finish any capture before removing its archive and retire a dead pane
        // so periodic capture cannot recreate the deleted history.
        if let capture = captures[sessionID] { _ = await capture.result }
        try await terminals.stop(sessionID: sessionID, force: true)
        try await ledger.forget(sessionID: sessionID)
        try await snapshots.delete(sessionID)
        try await store.delete(session: sessionID)
        sessions.removeValue(forKey: sessionID)
        snapshotStorage = try await snapshots.status(budgetBytes: settings.snapshotBudgetBytes)
    }

    /// Deletes a checkout, its records, and the history of its finished sessions.
    /// The checkout is removed from disk only when Git still lists it there.
    private func deleteWorktree(projectID: UUID, folderID: UUID, path requested: String, preview: Bool = false, discardChanges: Bool = false) async throws -> JSONValue {
        let snapshot = await store.reload()
        guard let folder = snapshot.projects.first(where: { $0.value.id == projectID })?.value.folders.first(where: { $0.id == folderID && $0.registered }) else { throw ChauffeurError("missing_folder", "Select a registered project folder") }
        let path = Paths.canonical(requested)
        guard path != folder.canonicalPath else { throw ChauffeurError("main_checkout", "The main checkout cannot be deleted", path: path) }
        let inventory = try await worktrees.inventory(at: folder.canonicalPath)
        let entry = inventory.first { $0.path == path }
        let records = snapshot.worktrees.filter { record in
            record.value.projectID == projectID && record.value.folderID == folderID
                && (Paths.canonical(record.value.path) == path || (entry?.gitIdentity != nil && record.value.gitIdentity == entry?.gitIdentity))
        }
        let recordIDs = Set(records.map(\.value.id))
        let affected = sessionsUsing(path: path, worktreeIDs: recordIDs, folderID: folderID, in: knownSessions(snapshot).filter { $0.projectID == projectID })
        guard !affected.contains(where: { $0.state.isLive || launching.contains($0.id) }) else {
            throw ChauffeurError("active_worktree", "Stop sessions using this worktree before deleting it", path: path)
        }
        if preview {
            var result = WorktreeDeletionPreview(hasChanges: false)
            if let entry, entry.availability ?? .available == .available {
                let changedFiles = try await worktrees.changedFiles(at: path)
                result.changedFiles = changedFiles
                result.hasChanges = !changedFiles.isEmpty
                let mainBranch = inventory.first?.branch ?? ""
                result.baseBranch = records.first?.value.baseBranch ?? (mainBranch.isEmpty ? nil : mainBranch)
                result.unmergedCommits = await worktrees.unmergedCommits(at: path, branch: entry.branch, base: result.baseBranch)
                (result.remoteBranch, result.unpushedCommits) = await worktrees.remoteStatus(at: path)
            }
            return try .from(result)
        }
        let removalID = records.first?.value.id ?? UUID()
        try checkoutClaims.beginRemoval(removalID, path: path, worktreeIDs: recordIDs, gitIdentity: entry?.gitIdentity, sessions: Array(sessions.values))
        defer { checkoutClaims.endRemoval(removalID) }
        var deletedCheckout = false
        if let entry {
            if entry.availability ?? .available == .available {
                let repositoryID = try await worktrees.repositoryID(at: folder.canonicalPath)
                var target = records.first?.value ?? Worktree(projectID: projectID, folderID: folderID, repositoryID: repositoryID, path: path, repositoryPath: folder.canonicalPath, branch: entry.branch, baseCommit: entry.commit, managed: false)
                target.path = path; target.repositoryPath = folder.canonicalPath; target.gitIdentity = target.gitIdentity ?? entry.gitIdentity
                try await worktrees.remove(target, liveSessions: Array(sessions.values), allowExternal: true, discardChanges: discardChanges)
                deletedCheckout = true
            } else {
                // The directory is already gone; only Git's stale entry remains.
                try await worktrees.prune(repositoryPath: folder.canonicalPath)
            }
        }
        if !deletedCheckout, let branch = entry?.branch ?? records.first?.value.branch {
            await worktrees.deleteBranchIfUnused(branch, repository: folder.canonicalPath)
        }
        for session in affected {
            try await ledger.forget(sessionID: session.id)
            try? await snapshots.delete(session.id)
            try await store.delete(session: session.id)
            sessions.removeValue(forKey: session.id)
        }
        for record in records { try await store.delete(worktree: record.value.id) }
        return .object(["path": .string(path), "deletedCheckout": .bool(deletedCheckout), "deletedSessions": .number(Double(affected.count)), "deletedRecords": .number(Double(records.count))])
    }
    private func registerWorktree(_ key: WorktreeRegistration) async throws -> Stored<Worktree> {
        let snapshot = await store.reload()
        guard let folder = snapshot.projects.first(where: { $0.value.id == key.projectID })?.value.folders.first(where: { $0.id == key.folderID && $0.registered }) else { throw ChauffeurError("missing_folder", "Select a registered repository") }
        let repositoryID = try await worktrees.repositoryID(at: folder.canonicalPath)
        guard let entry = try await worktrees.inventory(at: folder.canonicalPath).first(where: { $0.path == key.path }), entry.availability == .available else { throw ChauffeurError("missing_worktree", "Path is not available in this repository's Git worktree inventory") }
        var observation = RepositoryInventory(sourcePath: folder.canonicalPath, status: .available)
        observation.repositoryID = repositoryID; observation.entries = [entry]
        observation.legacyRepositoryID = try await worktrees.legacyRepositoryID(at: folder.canonicalPath)
        if var existing = snapshot.worktrees.first(where: {
            let record = $0.value
            let sameCheckout = record.gitIdentity != nil && record.gitIdentity == entry.gitIdentity
            let sameRepository = record.repositoryID == repositoryID || (record.repositoryIdentityVersion == nil && (sameCheckout || record.repositoryID == observation.legacyRepositoryID))
            return record.projectID == key.projectID && record.folderID == key.folderID && sameRepository && (sameCheckout || (record.gitIdentity == nil && record.path == key.path))
        }) {
            existing.value = await worktrees.reconciled(existing.value, inventory: observation)
            existing.value.registered = true
            return try await saveWorktree(existing.value, expectedVersion: existing.version)
        }
        var registered = Worktree(projectID: key.projectID, folderID: key.folderID, repositoryID: repositoryID, path: key.path, repositoryPath: folder.canonicalPath, branch: entry.branch, baseCommit: entry.commit, managed: false)
        registered.gitIdentity = entry.gitIdentity
        return try await saveWorktree(registered)
    }
    public func createWorktree(_ request: WorktreeCreationRequest) async throws -> Stored<Worktree> {
        let fingerprint = JSONCoding.digest(try JSONCoding.encode(request))
        guard let key = request.retryKey else { return try await performWorktreeCreation(request, fingerprint: nil) }
        if let (pendingFingerprint, task) = worktreeCreations[key] {
            guard fingerprint == pendingFingerprint else { throw ChauffeurError("retry_conflict", "Worktree request ID was already used with different fields") }
            return try await task.value
        }
        let task = Task { try await self.performWorktreeCreation(request, fingerprint: fingerprint) }
        worktreeCreations[key] = (fingerprint, task)
        defer { worktreeCreations.removeValue(forKey: key) }
        return try await task.value
    }
    private func performWorktreeCreation(_ request: WorktreeCreationRequest, fingerprint: String?) async throws -> Stored<Worktree> {
        let snapshot = await store.reload()
        if let key = request.retryKey, let existing = snapshot.worktrees.first(where: { $0.value.id == key }) {
            guard existing.value.creationRequestFingerprint == fingerprint else { throw ChauffeurError("retry_conflict", "Worktree request ID was already used with different fields") }
            return existing
        }
        guard let project = snapshot.projects.first(where: { $0.value.id == request.projectID && !$0.value.archived })?.value,
              let folder = project.folders.first(where: { $0.id == request.folderID && $0.registered }) else { throw ChauffeurError("missing_folder", "Select an available folder in an active project") }
        var worktree = try await worktrees.create(projectID: project.id, folder: folder, branch: request.branch, baseRef: request.baseRef)
        if let key = request.retryKey { worktree.id = key; worktree.creationRequestFingerprint = fingerprint }
        do { return try await saveWorktree(worktree) }
        catch { throw ChauffeurError("worktree_registration", "The worktree was created but its record could not be saved. Refresh Git Inventory and register the retained checkout", path: worktree.path) }
    }
    /// Stops the runtime's complete terminal inventory, including finished panes.
    /// Block new launches while cancelling startup and removing terminals.
    private func forceStopAllSessions() async throws {
        guard !stoppingAllSessions else { throw ChauffeurError("stop_pending", "All sessions are already being stopped") }
        stoppingAllSessions = true
        defer { stoppingAllSessions = false }
        let pending = Array(launchTasks.values)
        for task in pending { task.cancel() }
        for task in pending { _ = await task.result }
        for id in sessions.keys {
            stopGenerations[id, default: 0] += 1
            stopping.insert(id)
            try await ledger.revoke(sessionID: id)
        }
        var failures: [String] = []
        for pane in try await terminals.inventory() {
            guard let id = UUID(uuidString: pane.sessionName) else {
                failures.append("Unrecognized terminal: \(pane.sessionName)")
                continue
            }
            do { try await terminals.stop(sessionID: id, force: true) }
            catch { failures.append(error.localizedDescription) }
        }
        try await reconcile()
        guard try await terminals.inventory().isEmpty else {
            throw ChauffeurError("sessions_still_running", "Some terminals could not be stopped. \(failures.joined(separator: "; "))")
        }
    }

    public func launch(_ request: LaunchRequest, child: Delegation? = nil) async throws -> Session {
        guard !stoppingAllSessions else { throw ChauffeurError("stop_pending", "All sessions are being stopped") }
        // User retry UUID is also the durable session UUID. A retry after an IPC
        // timeout returns the original record, including failures, without spawn.
        let sessionID = child?.childID ?? request.retryKey
        let fingerprint = JSONCoding.digest(try JSONCoding.encode(request))
        if let existing = sessions[sessionID] {
            guard existing.launchRequestFingerprint == fingerprint else { throw ChauffeurError("retry_conflict", "Launch request ID was already used with different fields") }
            return existing
        }
        guard !launching.contains(sessionID) else { throw ChauffeurError("launch_pending", "Launch is still in progress. Retry with the same request ID") }
        guard !stopRequests.contains(sessionID) else { throw ChauffeurError("stop_pending", "Stop is still in progress") }
        launching.insert(sessionID)
        let task = Task { try await self.performLaunch(request, child: child, sessionID: sessionID, fingerprint: fingerprint) }
        launchTasks[sessionID] = task
        defer { launching.remove(sessionID); launchTasks.removeValue(forKey: sessionID) }
        return try await task.value
    }
    private func performLaunch(_ request: LaunchRequest, child: Delegation?, sessionID: UUID, fingerprint: String) async throws -> Session {
        try Task.checkCancellation()
        let snapshot = await store.reload()
        try Task.checkCancellation()
        guard let project = snapshot.projects.first(where: { $0.value.id == request.projectID })?.value, !project.archived else { throw ChauffeurError("missing_project", "Select an active project") }
        guard project.groups.contains(where: { $0.id == request.groupID && !$0.archived }) else { throw ChauffeurError("missing_group", "Select an active group in this project") }
        guard let folder = project.folders.first(where: { $0.id == request.folderID && $0.registered }) else { throw ChauffeurError("missing_folder", "Select a registered project folder") }
        var workingDirectory = folder.canonicalPath
        var selectedWorktree: Worktree?
        if let worktreeID = request.worktreeID {
            guard let worktree = snapshot.worktrees.first(where: { $0.value.id == worktreeID && $0.value.projectID == project.id && $0.value.folderID == folder.id && $0.value.registered })?.value else { throw ChauffeurError("missing_worktree", "Select a registered worktree for this repository") }
            workingDirectory = worktree.path
            selectedWorktree = worktree
        }
        let isShell = request.launchKind == .shell
        let set: PresetSet, preset: AgentPreset
        if isShell {
            // A shell is not an preset. It runs the login shell in the
            // checkout, has no configuration directory and never coordinates.
            guard child == nil else { throw ChauffeurError("invalid_argument", "Delegated sessions must launch an agent") }
            guard let team = snapshot.presetSets.first(where: { $0.value.id == project.presetSetID })?.value, !team.archived else {
                throw ChauffeurError("missing_set", "Select an active team before opening a terminal")
            }
            set = team
            var shell = AgentPreset(setID: set.id, name: "Shell", kind: .shell, executable: baseEnvironment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh", configurationDirectory: workingDirectory)
            shell.arguments = ["-l"]; shell.integration = .unavailable
            preset = shell
        } else {
            guard let storedSet = snapshot.presetSets.first(where: { $0.value.id == project.presetSetID })?.value, !storedSet.archived,
                  let storedPreset = snapshot.agents(in: storedSet).first(where: { $0.id == request.presetID }) else {
                throw ChauffeurError("missing_preset", "Project's team is empty or selected agent preset is unavailable")
            }
            set = storedSet; preset = storedPreset
        }
        let additionalPaths = try (isShell ? [] : request.additionalFolderIDs).filter { $0 != folder.id }.map { id in
            guard let extra = project.folders.first(where: { $0.id == id && $0.registered }) else { throw ChauffeurError("missing_folder", "Additional project folder is unavailable") }
            return try Paths.directory(extra.canonicalPath)
        }
        // Shells never claim a checkout: they neither block agents nor need sharing consent.
        try checkoutClaims.beginLaunch(sessionID, paths: [workingDirectory] + additionalPaths, worktreeID: request.worktreeID, allowSharedCheckout: isShell || request.allowSharedCheckout, occupies: !isShell)
        defer { checkoutClaims.endLaunch(sessionID) }
        var launch = LaunchSnapshot(preset: preset, set: set, executablePath: preset.executable, executableVersion: isShell ? "shell" : "unverified", workingDirectory: workingDirectory, additionalPaths: additionalPaths)
        if set.agentSelection != nil {
            launch.configurationEnvironment = snapshot.configurationEnvironment(in: set)
            launch.configurationUsesDefault = !isShell && (set.configurationDirectories?[preset.kind.rawValue] ?? "").isEmpty
        } else if isShell { launch.configurationEnvironment = shellAgentExports(project: project, snapshot: snapshot) }
        var session = Session(projectID: project.id, groupID: request.groupID, title: request.title, launch: launch, folderID: folder.id)
        session.id = sessionID; session.worktreeID = request.worktreeID; session.initialTask = request.task
        session.launchRequestFingerprint = fingerprint
        session.parentID = child?.parentID; session.delegationID = child?.id; session.runtimeID = id
        if preset.kind == .claude { session.nativeConversationID = session.id.uuidString }
        do {
            try await persist(session)
            try Task.checkCancellation()
            try preset.validate()
            try LaunchPolicy.validateAdditionalDirectories(additionalPaths, preset: preset)
            session.launch.workingDirectory = try Paths.directory(workingDirectory)
            var checkouts: [CheckoutIdentity] = []
            for path in [session.launch.workingDirectory] + additionalPaths {
                checkouts.append(try await worktrees.checkoutIdentity(at: path))
                try Task.checkCancellation()
            }
            let identities = checkouts.compactMap(\.gitIdentity), primaryIdentity = checkouts.first?.gitIdentity
            try checkoutClaims.setGitIdentities(sessionID, identities: identities, primary: primaryIdentity)
            session.launch.gitWorktreeIdentities = identities
            session.launch.checkoutIdentities = checkouts
            if let selectedWorktree {
                let repositoryID = try await worktrees.repositoryID(at: session.launch.workingDirectory)
                let identity = try await worktrees.identity(at: session.launch.workingDirectory)
                let legacyID = selectedWorktree.repositoryIdentityVersion == nil ? try await worktrees.legacyRepositoryID(at: session.launch.workingDirectory) : nil
                let sameRepository = repositoryID == selectedWorktree.repositoryID || (selectedWorktree.repositoryIdentityVersion == nil && (selectedWorktree.repositoryID == legacyID || identity == selectedWorktree.gitIdentity))
                try Task.checkCancellation()
                guard sameRepository, selectedWorktree.gitIdentity == nil || identity == selectedWorktree.gitIdentity else {
                    throw ChauffeurError("worktree_unavailable", "The selected checkout was replaced. Refresh the Git inventory and select its current record", path: session.launch.workingDirectory)
                }
            }
            session.launch.configurationPath = launch.configurationUsesDefault == true ? Paths.canonical(preset.configurationDirectory) : try Paths.directory(preset.configurationDirectory)
            session.launch.executablePath = try Paths.executable(preset.executable, environment: baseEnvironment)
            let sharing = sessions.values.filter { peer in
                peer.id != session.id && peer.state.isLive && peer.launch.preset.kind.isAgent && (peer.launch.workingDirectory == session.launch.workingDirectory
                    || primaryIdentity.map { (peer.launch.gitWorktreeIdentities ?? []).contains($0) } == true)
            }
            guard isShell || sharing.isEmpty || request.allowSharedCheckout else { throw ChauffeurError("shared_checkout", "Checkout is already used by: \(sharing.map(\.title).joined(separator: ", ")). Explicitly choose to share it", path: workingDirectory) }
            let token = isShell ? "" : try await ledger.issueGrant(sessionID: session.id)
            try Task.checkCancellation()
            var environment = try LaunchPolicy.environment(base: baseEnvironment, preset: preset, projectID: session.projectID, sessionID: session.id, token: token, configurationEnvironment: session.launch.configurationEnvironment, allowMissingConfiguration: session.launch.configurationUsesDefault == true)
            environment["CHAUFFEUR_SOCKET"] = root.appendingPathComponent("runtime/runtime.sock").path
            let shellExports = isShell ? (session.launch.configurationEnvironment ?? shellAgentExports(project: project, snapshot: snapshot)) : [:]
            environment.merge(shellExports) { _, export in export }
            let coordination = !isShell && request.coordinationEnabled
            let integration = root.appendingPathComponent("runtime/integration/\(session.id)")
            if !isShell {
                let capabilities = try await CLIAdapter.capabilities(executable: session.launch.executablePath, kind: preset.kind, environment: environment)
                try Task.checkCancellation()
                session.launch.executableVersion = capabilities.version
                if !additionalPaths.isEmpty && !capabilities.additionalDirectories { throw ChauffeurError("unsupported_directories", "This CLI does not support additional directories") }
                if coordination && (!capabilities.coordination || endpoint == nil) { throw ChauffeurError("integration_unavailable", capabilities.limitation ?? "MCP service is unavailable. Retry or explicitly select basic terminal mode") }
                session.launch.preset.integration = coordination ? .unverified : .unavailable
                try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let arguments = try CLIAdapter.arguments(session: session, endpoint: endpoint ?? "", ctlPath: ctlPath, integrationDirectory: integration, coordination: coordination, resume: false)
            try await persist(session)
            try Task.checkCancellation()
            if preset.kind == .shell {
                environment = try ShellStartup.environment(executable: session.launch.executablePath, environment: environment, exports: shellExports, directory: root.appendingPathComponent("runtime/shell-startup/\(session.id)"))
            }
            let pane = try await terminals.spawn(session: session, payload: ExecPayload(executable: session.launch.executablePath, arguments: arguments, environment: environment, directory: session.launch.workingDirectory, preamble: ShellAgentEnvironment.exportCommand(shellExports)), scrollback: settings.scrollbackLines)
            try Task.checkCancellation()
            session.processID = pane.processID; session.terminalIdentity = pane.paneID; session.state = .activityUnknown
            try await persist(session)
            try Task.checkCancellation()
            if child == nil && !isShell {
                do { try await store.rememberPreset(preset.id, projectID: project.id, setID: set.id) }
                catch let error as ChauffeurError { record(error) }
                catch { record(ChauffeurError("preset_preference", "The session started, but its agent preset choice could not be saved")) }
            }
            try Task.checkCancellation()
            return session
        } catch {
            throw try await finishFailedStartup(session, error: error)
        }
    }
    private func resume(_ sessionID: UUID) async throws -> Session {
        let generation = stopGenerations[sessionID, default: 0]
        try await reconcile()
        guard !stoppingAllSessions, generation == stopGenerations[sessionID, default: 0], !stopRequests.contains(sessionID) else { throw ChauffeurError("stop_pending", "Stop is still in progress. Resume after it finishes") }
        guard let session = sessions[sessionID], !session.state.isLive else { throw ChauffeurError("already_live", "Reattach the live session instead of resuming") }
        guard session.nativeConversationID != nil else { throw ChauffeurError("resume_unavailable", "No native conversation ID is available. Create a new session explicitly") }
        guard !launching.contains(sessionID) else { throw ChauffeurError("launch_pending", "Resume is already in progress") }
        launching.insert(sessionID); stopping.remove(sessionID)
        let task = Task { try await self.performResume(session) }
        launchTasks[sessionID] = task
        defer { launching.remove(sessionID); launchTasks.removeValue(forKey: sessionID) }
        return try await task.value
    }
    private func performResume(_ recorded: Session) async throws -> Session {
        var session = recorded
        let sessionID = session.id
        try Task.checkCancellation()
        try checkoutClaims.beginLaunch(sessionID, paths: [session.launch.workingDirectory] + session.launch.additionalPaths, worktreeID: session.worktreeID)
        do { try checkoutClaims.setGitIdentities(sessionID, identities: session.launch.gitWorktreeIdentities ?? []) }
        catch { checkoutClaims.endLaunch(sessionID); throw error }
        defer { checkoutClaims.endLaunch(sessionID) }
        // A rejected resume keeps the ended session and its saved terminal.
        // Preflight must finish before stopping the pane or persisting startup.
        try await worktrees.validateResume(session.launch)
        if session.launch.configurationUsesDefault != true { _ = try Paths.directory(session.launch.configurationPath) }
        try Task.checkCancellation()
        do {
            try await terminals.stop(sessionID: sessionID, force: true)
            try Task.checkCancellation()
            session.state = .starting; session.error = nil; session.failureCode = nil; session.exitStatus = nil; session.runtimeID = id; try await persist(session)
            try Task.checkCancellation()
            let token = try await ledger.issueGrant(sessionID: sessionID)
            try Task.checkCancellation()
            var preset = session.launch.preset; preset.configurationDirectory = session.launch.configurationPath
            var environment = try LaunchPolicy.environment(base: baseEnvironment, preset: preset, projectID: session.projectID, sessionID: sessionID, token: token, configurationEnvironment: session.launch.configurationEnvironment, allowMissingConfiguration: session.launch.configurationUsesDefault == true)
            environment["CHAUFFEUR_SOCKET"] = root.appendingPathComponent("runtime/runtime.sock").path
            let integration = root.appendingPathComponent("runtime/integration/\(session.id)")
            try FileManager.default.createDirectory(at: integration, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let arguments = try CLIAdapter.arguments(session: session, endpoint: endpoint ?? "", ctlPath: ctlPath, integrationDirectory: integration, coordination: session.launch.preset.integration != .unavailable, resume: true)
            let pane = try await terminals.spawn(session: session, payload: ExecPayload(executable: session.launch.executablePath, arguments: arguments, environment: environment, directory: session.launch.workingDirectory), scrollback: settings.scrollbackLines)
            try Task.checkCancellation()
            session.processID = pane.processID; session.terminalIdentity = pane.paneID; session.state = .activityUnknown
            try await persist(session)
            try Task.checkCancellation()
            return session
        } catch {
            throw try await finishFailedStartup(session, error: error)
        }
    }
    private func finishFailedStartup(_ recorded: Session, error: Error) async throws -> Error {
        var session = recorded
        let failure: Error = error is CancellationError || Task.isCancelled
            ? ChauffeurError("launch_cancelled", "Session startup was stopped") : error
        // This task deliberately does not inherit cancellation: cleanup must
        // finish before the launch reservation can be released.
        try await Task { try await self.terminals.stop(sessionID: session.id, force: true) }.value
        session.state = (failure as? ChauffeurError)?.code == "launch_cancelled" ? .interrupted : .failed
        session.error = (failure as? ChauffeurError)?.errorDescription ?? "Session startup failed"
        session.failureCode = DiagnosticCode.redacting((failure as? ChauffeurError)?.code).rawValue
        session.processID = nil; session.terminalIdentity = nil; session.updatedAt = Date()
        try await ledger.revoke(sessionID: session.id); try await persist(session)
        return failure
    }
    private func event(_ params: JSONValue) async throws -> JSONValue {
        let sessionID = try params.uuid("sessionID"), token = try params.requiredString("token")
        let caller = try await ledger.authenticate(token)
        guard caller.sessionID == sessionID, var session = sessions[sessionID], session.state.isLive else { throw ChauffeurError("unauthorized", "Event does not belong to this session") }
        var notification: AttentionReason?
        switch try params.requiredString("event") {
        case "running": session.state = .running
        case "turn-finished": session.state = .turnFinished; session.unread = true; notification = .completion
        case "needs-attention":
            if session.state != .needsAttention { notification = .input }
            session.state = .needsAttention; session.unread = true
        default: throw ChauffeurError("unknown_event", "Unsupported lifecycle event")
        }
        if let nativeID = params["nativeConversationID"].string, UUID(uuidString: nativeID) != nil {
            if let previous = session.nativeConversationID, previous != nativeID { throw ChauffeurError("conversation_mismatch", "Hook reported a different native conversation") }
            session.nativeConversationID = nativeID
        }
        session.updatedAt = Date(); try await persist(session, notification: notification); return .object(["accepted": .bool(true)])
    }
    /// Keeps exactly one non-archived team flagged as default while any exists. `preferring`
    /// names the team the user just made default; otherwise an already flagged team keeps the role,
    /// and a store with none flagged (older data, or the default was deleted or archived) promotes
    /// the first team by name.
    private func normalizeDefaultTeam(preferring: UUID? = nil) async throws {
        let stored = await store.refresh().presetSets
        let usable = stored.map(\.value).filter { !$0.archived }
        let byName = usable.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let winner = preferring.flatMap { id in usable.first { $0.id == id }?.id }
            ?? byName.first { $0.isDefault }?.id
            ?? byName.first?.id
        for record in stored {
            var set = record.value
            let shouldBeDefault = set.id == winner
            guard set.isDefault != shouldBeDefault else { continue }
            set.isDefault = shouldBeDefault
            try await store.save(set, expectedVersion: record.version)
        }
    }

    /// Both team directories apply even without an enabled agent of that harness.
    /// Keep missing paths explicit so a shell cannot fall back to another account.
    private func shellAgentExports(project: Project, snapshot: StoreSnapshot) -> [String: String] {
        guard let set = snapshot.presetSets.first(where: { $0.value.id == project.presetSetID })?.value else { return [:] }
        return snapshot.configurationEnvironment(in: set)
    }

    public func attach(sessionID: UUID, sink: any TerminalOutputSink, cols: Int, rows: Int, takeControl: Bool) async throws -> AttachmentGeneration {
        guard sessions[sessionID]?.state.isLive == true else { throw ChauffeurError("not_live", "Session is not live. Inspect its details or resume explicitly") }
        return try await terminals.attach(sessionID: sessionID, sink: sink, cols: cols, rows: rows, takeControl: takeControl)
    }
    public func callTool(token: String, name: String, arguments: JSONValue) async throws -> JSONValue {
        let caller = try await ledger.authenticate(token)
        try MCPTools.validate(name: name, arguments: arguments)
        var entry = RuntimeLogEntry(.toolCalled, runtimeID: id)
        entry.tool = DiagnosticTool(rawValue: name); entry.sessionID = caller.sessionID
        entry.projectID = caller.scope.projectID; entry.groupID = caller.scope.groupID
        logs?.append(entry)
        switch name {
        case "chauffeur_discover":
            let snapshot = await store.current()
            guard let project = snapshot.projects.first(where: { $0.value.id == caller.scope.projectID })?.value else { throw ChauffeurError("project_unavailable", "Project metadata is unavailable") }
            // Shells share the group but cannot read an inbox.
            let members = try await ledger.peers(caller).filter { $0.launch.preset.kind.isAgent }
            let current = members.first { $0.id == caller.sessionID }
            let peers = members.map { session -> JSONValue in
                .object(["id": .string(session.id.uuidString), "title": .string(session.title), "status": .string(session.state.label), "workingDirectory": .string(session.launch.workingDirectory), "preset": .string(session.launch.preset.name), "parentID": session.parentID.map { .string($0.uuidString) } ?? .null])
            }
            return .object(["sessionID": .string(caller.sessionID.uuidString), "parentID": current?.parentID.map { .string($0.uuidString) } ?? .null, "delegationID": current?.delegationID.map { .string($0.uuidString) } ?? .null, "projectID": .string(project.id.uuidString), "project": .string(project.name), "groupID": .string(caller.scope.groupID.uuidString), "group": .string(project.groups.first { $0.id == caller.scope.groupID }?.name ?? "Unavailable"), "repositories": try .from(project.folders.filter(\.registered)), "presets": .array(snapshot.agents(teamID: project.presetSetID).map { .object(["id": .string($0.id.uuidString), "name": .string($0.name), "kind": .string($0.kind.rawValue)]) }), "peers": .array(peers)])
        case "chauffeur_send_message":
            return try .from(await ledger.send(caller: caller, recipientID: arguments.uuid("recipientID"), body: arguments.requiredString("body"), references: arguments["references"].array.compactMap(\.string), retryKey: arguments.requiredString("retryKey")))
        case "chauffeur_inbox":
            let acknowledge = try arguments["acknowledge"].array.map { item -> UUID in
                guard let value = item.string.flatMap(UUID.init(uuidString:)) else { throw ChauffeurError("invalid_argument", "Acknowledge IDs must be UUIDs") }; return value
            }
            let wait = arguments["waitSeconds"].int ?? 0
            try Validation.require((0...25).contains(wait), "Inbox wait must be between 0 and 25 seconds")
            var incoming = try await ledger.inbox(caller: caller, acknowledge: acknowledge)
            let deadline = ContinuousClock.now.advanced(by: .seconds(wait))
            while incoming.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(200))
                let currentCaller = try await ledger.authenticate(token)
                incoming = try await ledger.inbox(caller: currentCaller)
            }
            return try .from(incoming)
        case "chauffeur_reply":
            let message = try await ledger.message(arguments.uuid("messageID"), caller: caller)
            return try .from(await ledger.send(caller: caller, recipientID: message.senderID, body: arguments.requiredString("body"), references: arguments["references"].array.compactMap(\.string), retryKey: arguments.requiredString("retryKey"), replyToID: message.id))
        case "chauffeur_delegation_status": return try .from(await ledger.delegation(arguments.uuid("delegationID"), caller: caller))
        case "chauffeur_report_result": return try .from(await ledger.reportResult(caller: caller, delegationID: arguments.uuid("delegationID"), result: arguments.requiredString("result"), retryKey: arguments.requiredString("retryKey")))
        case "chauffeur_delegate":
            let (reserved, isNew) = try await ledger.reserveDelegation(caller: caller, task: arguments.requiredString("task"), presetID: arguments.uuid("presetID"), folderID: arguments.uuid("folderID"), shareCheckout: arguments["shareCheckout"].bool ?? false, retryKey: arguments.requiredString("retryKey"), limit: settings.maxLiveChildren)
            guard isNew else { return try .from(reserved) }
            var delegation = reserved
            do {
                let snapshot = await store.current()
                guard let project = snapshot.projects.first(where: { $0.value.id == caller.scope.projectID })?.value,
                      let folder = project.folders.first(where: { $0.id == delegation.folderID && $0.registered }) else { throw ChauffeurError("missing_folder", "Delegation folder is unavailable in this project") }
                guard snapshot.agents(teamID: project.presetSetID).contains(where: { $0.id == delegation.presetID }) else { throw ChauffeurError("missing_preset", "Delegation agent preset is unavailable in this project's set") }
                delegation.state = .launching; try await ledger.updateDelegation(delegation)
                if !delegation.shareCheckout {
                    let worktree = try await worktrees.create(projectID: project.id, folder: folder, branch: "chauffeur/\(String(delegation.id.uuidString.prefix(12)).lowercased())", baseRef: "HEAD")
                    try await saveWorktree(worktree); delegation.worktreeID = worktree.id
                    try await ledger.updateDelegation(delegation)
                }
                _ = try await ledger.authenticate(token)
                let request = LaunchRequest(projectID: caller.scope.projectID, groupID: caller.scope.groupID, presetID: delegation.presetID, folderID: delegation.folderID, title: String(delegation.task.prefix(100)), worktreeID: delegation.worktreeID, task: delegation.task, allowSharedCheckout: delegation.shareCheckout, coordinationEnabled: true, retryKey: delegation.childID)
                _ = try await launch(request, child: delegation)
                delegation.state = .running
            } catch {
                delegation.state = .failed; delegation.error = (error as? ChauffeurError)?.errorDescription ?? "Delegation failed; any created worktree is retained"
                record(error as? ChauffeurError ?? ChauffeurError("operation_failed", "Delegation failed"))
            }
            try await ledger.updateDelegation(delegation)
            return try .from(delegation)
        default: throw ChauffeurError("unknown_tool", "Unknown Chauffeur tool")
        }
    }
}
