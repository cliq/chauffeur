import Foundation
import ChauffeurCore
import ChauffeurRemoteProtocol

/// Translates mobile remote operations into runtime calls. Connection-level
/// operations (hello, pair, terminal attachment) belong to the listener; this
/// actor owns inventory, worktree previews and idempotent launches.
public actor RemoteOperationHandlers {
    private let runtime: RuntimeCoordinator
    private let journal: RemoteOperationJournal
    private let hostName: String
    private let isAttached: @Sendable (UUID) async -> Bool
    private var journalLoaded = false
    /// Launches still running on this actor, by operation key.
    private var tasks: [UUID: Task<OperationStatus, Never>] = [:]
    private var revision: UInt64 = 0
    private var lastDigest: String?

    public init(runtime: RuntimeCoordinator, root: URL, hostName: String, isAttached: @escaping @Sendable (UUID) async -> Bool = { _ in false }) {
        self.runtime = runtime
        self.journal = RemoteOperationJournal(root: root)
        self.hostName = hostName
        self.isAttached = isAttached
    }

    // MARK: - Dispatch

    /// Handles every operation except hello, pair, attachTerminal, terminalResize
    /// and detachTerminal, which the listener layer owns.
    public func handle(_ operation: RemoteOperation, deviceID: UUID) async -> Result<RemoteResult, RemoteError> {
        switch operation {
        case .hello, .pair, .attachTerminal, .terminalResize, .detachTerminal:
            return .failure(RemoteError(code: "unsupported_operation", message: "\(operation.kind) is handled by the connection layer"))
        case .listInventory:
            // `sinceRevision` is accepted but the full inventory is always returned for now.
            do { return .success(.inventory(try await inventory())) }
            catch { return .failure(Self.remoteError(error)) }
        case .getSessionProgress(let request):
            do {
                let snapshot = try await runtime.snapshot().decode(RemoteInventoryBuilder.RuntimeSnapshotView.self)
                guard let session = snapshot.sessions.first(where: { $0.id == request.sessionID }) else {
                    throw ChauffeurError("missing_session", "This session no longer exists on the Mac")
                }
                let panel = try await Task.detached(priority: .utility) { try RemoteProgressReader.panel(session: session) }.value
                return .success(.sessionProgress(panel))
            } catch { return .failure(Self.remoteError(error)) }
        case .previewWorktreeDestination(let request):
            do {
                let params: JSONValue = .object([
                    "projectID": .string(request.projectID.uuidString),
                    "folderID": .string(request.folderID.uuidString),
                    "branch": .string(request.branch)
                ])
                let response = try await runtime.handle(IPCRequest("previewWorktree", params: params))
                guard let path = response["path"].string else { throw ChauffeurError("invalid_response", "The runtime did not return a worktree destination") }
                return .success(.worktreeDestination(WorktreeDestinationPreview(path: path)))
            } catch { return .failure(Self.remoteError(error)) }
        case .launch(let request):
            return .success(.operation(await launch(request, deviceID: deviceID)))
        case .getOperationStatus(let request):
            if let status = await operationStatus(key: request.operationKey) { return .success(.operation(status)) }
            return .failure(RemoteError(code: "unknown_operation", message: "No launch with this operation key was recorded on this Mac."))
        }
    }

    // MARK: - Inventory

    public func inventory() async throws -> InventorySnapshot {
        let snapshot = try await runtime.snapshot()
        let view = try snapshot.decode(RemoteInventoryBuilder.RuntimeSnapshotView.self)
        var attached = Set<UUID>()
        for session in view.sessions where await isAttached(session.id) { attached.insert(session.id) }
        var built = RemoteInventoryBuilder.build(view: view, hostName: hostName, revision: revision, isAttached: { attached.contains($0) })
        let digest = RemoteInventoryBuilder.digest(built)
        if digest != lastDigest { revision += 1; lastDigest = digest }
        built.revision = revision
        return built
    }

    public func currentRevision() -> UInt64 { revision }

    // MARK: - Launch

    public func operationStatus(key: UUID) async -> OperationStatus? {
        await ensureJournalLoaded()
        return await journal.record(for: key)?.status
    }

    /// A lost response can never duplicate work: the same key with the same
    /// fingerprint resolves to the original worktree and session, while a
    /// different fingerprint is refused without touching the runtime.
    public func launch(_ request: LaunchOperationRequest, deviceID: UUID) async -> OperationStatus {
        await ensureJournalLoaded()
        let key = request.operationKey
        let existing = await journal.record(for: key)
        if let existing {
            guard existing.fingerprint == request.fingerprint else {
                return OperationStatus(operationKey: key, phase: .failed, worktreeID: existing.status.worktreeID, sessionID: existing.status.sessionID,
                                       error: RemoteError(code: "operation_conflict", message: "This retry does not match the original request. Start a new launch."), updatedAt: Date())
            }
            if tasks[key] != nil { return existing.status }
            if existing.status.phase == .completed { return existing.status }
            // failed, worktreeReady, or a phase left behind by a previous process: run again.
        }
        let task = Task { await self.perform(request, deviceID: deviceID, previous: existing?.status) }
        tasks[key] = task
        let status = await task.value
        tasks.removeValue(forKey: key)
        return status
    }

    private func perform(_ request: LaunchOperationRequest, deviceID: UUID, previous: OperationStatus?) async -> OperationStatus {
        let key = request.operationKey
        let context = LaunchContext(request: request, deviceID: deviceID, worktreeKey: RemoteOperationKeys.worktreeKey(for: key), sessionKey: RemoteOperationKeys.sessionKey(for: key))
        var status = await persist(context, OperationStatus(operationKey: key, phase: request.newWorktree == nil ? .launching : .creatingWorktree, worktreeID: previous?.worktreeID, updatedAt: Date()))

        let spec = request.launch
        let snapshot = await runtime.store.reload()
        guard let project = snapshot.projects.first(where: { $0.value.id == spec.projectID })?.value else {
            return await fail(context, status, RemoteError(code: "unknown_project", message: "This project no longer exists on the Mac."))
        }
        guard let folder = project.folders.first(where: { $0.id == spec.folderID && $0.registered }) else {
            return await fail(context, status, RemoteError(code: "unknown_folder", message: "This folder is no longer part of the project."))
        }
        let group: AgentGroup?
        if let groupID = spec.groupID { group = project.groups.first { $0.id == groupID && !$0.archived } }
        else { group = project.groups.first { $0.isDefault && !$0.archived } ?? project.groups.first { !$0.archived } }
        guard let group else {
            return await fail(context, status, RemoteError(code: "unknown_group", message: spec.groupID == nil ? "This project has no active group." : "This group is no longer active in the project."))
        }
        var preset: AgentPreset?
        if let presetID = spec.agentPresetID {
            let set = snapshot.presetSets.first { $0.value.id == project.presetSetID }?.value
            preset = set?.archived == false ? snapshot.agents(teamID: project.presetSetID).first { $0.id == presetID } : nil
            guard preset != nil else {
                return await fail(context, status, RemoteError(code: "unknown_preset", message: "This agent preset is no longer available for the project."))
            }
        }

        var worktreeID = spec.worktreeID
        var branch = spec.worktreeID.flatMap { id in snapshot.worktrees.first { $0.value.id == id }?.value.branch } ?? ""
        do {
            if let newWorktree = request.newWorktree {
                let creation = WorktreeCreationRequest(projectID: project.id, folderID: folder.id, branch: newWorktree.branch, baseRef: newWorktree.baseRef, retryKey: context.worktreeKey)
                let created = try await runtime.createWorktree(creation).value
                guard created.registered, created.availability == .available else {
                    throw ChauffeurError("worktree_unavailable", "The worktree for this launch was removed. Start a new launch.", path: created.path)
                }
                worktreeID = created.id; branch = created.branch
                status = await persist(context, OperationStatus(operationKey: key, phase: .worktreeReady, worktreeID: created.id, updatedAt: Date()))
            }
            status = await persist(context, OperationStatus(operationKey: key, phase: .launching, worktreeID: worktreeID, updatedAt: Date()))
            let title = spec.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            let launchRequest: LaunchRequest
            if let preset {
                launchRequest = LaunchRequest(projectID: project.id, groupID: group.id, presetID: preset.id, folderID: folder.id,
                                              title: title ?? "\(preset.name) · \(folder.name)", worktreeID: worktreeID, additionalFolderIDs: [], task: spec.task,
                                              allowSharedCheckout: request.newWorktree == nil && spec.allowSharedCheckout, coordinationEnabled: false, retryKey: context.sessionKey)
            } else {
                launchRequest = LaunchRequest.shell(projectID: project.id, groupID: group.id, folderID: folder.id,
                                                    title: title ?? "Shell · \(branch.isEmpty ? folder.name : branch)", worktreeID: worktreeID, retryKey: context.sessionKey)
            }
            let session = try await runtime.launch(launchRequest)
            if session.state == .failed {
                // A retry of a launch the runtime already recorded as failed returns that record instead of throwing.
                status.sessionID = session.id
                return await fail(context, status, RemoteError(code: session.failureCode ?? "launch_failed", message: session.error ?? "The session failed to start."))
            }
            return await persist(context, OperationStatus(operationKey: key, phase: .completed, worktreeID: worktreeID, sessionID: session.id, updatedAt: Date()))
        } catch {
            return await fail(context, status, Self.remoteError(error))
        }
    }

    private struct LaunchContext: Sendable {
        var request: LaunchOperationRequest
        var deviceID: UUID
        var worktreeKey: UUID
        var sessionKey: UUID
    }

    /// Records the phase change. The in-memory record is updated even when the
    /// disk write fails, so a retry in this process still resolves correctly.
    private func persist(_ context: LaunchContext, _ status: OperationStatus) async -> OperationStatus {
        try? await journal.upsert(RemoteOperationRecord(key: context.request.operationKey, fingerprint: context.request.fingerprint, deviceID: context.deviceID, status: status, worktreeKey: context.worktreeKey, sessionKey: context.sessionKey))
        return status
    }

    private func fail(_ context: LaunchContext, _ status: OperationStatus, _ error: RemoteError) async -> OperationStatus {
        await persist(context, OperationStatus(operationKey: status.operationKey, phase: .failed, worktreeID: status.worktreeID, sessionID: status.sessionID, error: error, updatedAt: Date()))
    }

    /// Resolves launches the previous process left mid-flight from what the
    /// store now holds: a session means it completed, a worktree alone means the
    /// launch never happened, and nothing means the client must retry.
    public func reconcileAfterRestart() async {
        await ensureJournalLoaded()
        let snapshot = await runtime.store.reload()
        for record in await journal.all() where [.creatingWorktree, .launching].contains(record.status.phase) && tasks[record.key] == nil {
            var updated = record
            updated.status.updatedAt = Date()
            updated.status.error = nil
            if snapshot.sessions.contains(where: { $0.value.id == record.sessionKey }) {
                updated.status.phase = .completed; updated.status.sessionID = record.sessionKey
            } else if snapshot.worktrees.contains(where: { $0.value.id == record.worktreeKey }) {
                updated.status.phase = .worktreeReady; updated.status.worktreeID = record.worktreeKey
            } else {
                updated.status.phase = .failed
                updated.status.error = RemoteError(code: "interrupted", message: "The Mac restarted before this launch finished. Retry to continue.", retryable: true)
            }
            try? await journal.upsert(updated)
        }
    }

    // MARK: - Helpers

    private func ensureJournalLoaded() async {
        guard !journalLoaded else { return }
        // A corrupt journal is treated as empty; the next launch rewrites it.
        try? await journal.load()
        journalLoaded = true
    }

    private static func remoteError(_ error: Error) -> RemoteError {
        if let error = error as? ChauffeurError {
            return RemoteError(code: error.code, message: error.message, retryable: ["launch_pending", "worktree_pending"].contains(error.code))
        }
        if let error = error as? RemoteError { return error }
        return RemoteError(code: "internal_error", message: error.localizedDescription)
    }
}
