import Foundation
import Observation
import ChauffeurRemoteProtocol
import ChauffeurTerminalInterface

// MARK: - Pending operation journal

/// Remembers launch operation keys that were sent but not yet resolved, so a launch whose
/// response was lost can be reconciled after reconnecting instead of being repeated.
public protocol PendingOperationJournal: Sendable {
    func pendingKeys() -> [UUID]
    func record(_ key: UUID)
    func remove(_ key: UUID)
}

public final class UserDefaultsOperationJournal: PendingOperationJournal, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "chauffeur.remote.pendingOperations") {
        self.defaults = defaults
        self.key = key
    }

    /// One journal per paired Mac: another Mac would report these keys as unknown and drop them.
    public static func forHost(_ hostID: UUID, defaults: UserDefaults = .standard) -> UserDefaultsOperationJournal {
        UserDefaultsOperationJournal(defaults: defaults, key: "chauffeur.remote.pendingOperations.\(hostID.uuidString)")
    }

    /// Moves keys recorded by builds that paired one Mac into that Mac's journal.
    public static func migrateSharedJournal(to hostID: UUID, defaults: UserDefaults = .standard) {
        let shared = UserDefaultsOperationJournal(defaults: defaults)
        let target = forHost(hostID, defaults: defaults)
        for key in shared.pendingKeys() {
            target.record(key)
            shared.remove(key)
        }
    }

    public func pendingKeys() -> [UUID] {
        lock.withLock { readKeys() }
    }

    public func record(_ key: UUID) {
        lock.withLock {
            var keys = readKeys()
            guard !keys.contains(key) else { return }
            keys.append(key)
            writeKeys(keys)
        }
    }

    public func remove(_ key: UUID) {
        lock.withLock {
            var keys = readKeys()
            keys.removeAll { $0 == key }
            writeKeys(keys)
        }
    }

    private func readKeys() -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func writeKeys(_ keys: [UUID]) {
        if keys.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(keys.map(\.uuidString), forKey: key)
        }
    }
}

public final class InMemoryOperationJournal: PendingOperationJournal, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID] = []

    public init() {}

    public func pendingKeys() -> [UUID] {
        lock.withLock { keys }
    }

    public func record(_ key: UUID) {
        lock.withLock {
            if !keys.contains(key) { keys.append(key) }
        }
    }

    public func remove(_ key: UUID) {
        lock.withLock { keys.removeAll { $0 == key } }
    }
}

// MARK: - Host session

public enum HostConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected(HostInfo)
    case unavailable(message: String)
}

/// The app-facing model for one saved Mac: connection state, the latest inventory, launches
/// with crash-safe operation keys, and terminal controllers that share its connection.
@MainActor
@Observable
public final class RemoteHostSession {
    public let savedHost: SavedHost
    public private(set) var connectionState: HostConnectionState = .disconnected
    public private(set) var inventory: InventorySnapshot?
    /// True once the inventory may no longer match the Mac (after any disconnect).
    public private(set) var inventoryIsStale = false
    public var isKeepAwakeSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.keepAwake)
    }

    public var isFileUploadSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.fileUpload)
    }

    public var isTicketResolutionSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.ticketResolution)
    }

    public var isLaunchCoordinationSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.launchCoordination)
    }

    public var isGroupCreationSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.groupCreation)
    }

    public var isSessionStopSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.sessionStop)
    }

    public var isDocumentsSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.documents)
    }

    public var isDocumentChunksSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.documentChunks)
    }

    public var isProjectSuspensionSupported: Bool {
        guard case .connected(let host) = connectionState else { return false }
        return host.capabilities.contains(RemoteProtocol.projectSuspension)
    }

    @ObservationIgnored private let journal: any PendingOperationJournal
    @ObservationIgnored private let clientName: String
    @ObservationIgnored private let clientVersion: String
    @ObservationIgnored private let makeConnection: @MainActor (SavedHost) -> RemoteConnection
    @ObservationIgnored private var connection: RemoteConnection?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var connectionStateTask: Task<Void, Never>?
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var refreshRequestedAgain = false

    public init(
        host: SavedHost,
        journal: any PendingOperationJournal,
        clientName: String = "Chauffeur",
        clientVersion: String = "0.1",
        makeConnection: @escaping @MainActor (SavedHost) -> RemoteConnection = { host in
            RemoteConnection(
                transport: NetworkTransport(
                    endpoint: RemoteEndpoint(host: host.host, port: host.port),
                    presharedKey: host.remoteAccessKey
                )
            )
        }
    ) {
        self.savedHost = host
        self.journal = journal
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.makeConnection = makeConnection
    }

    deinit {
        eventsTask?.cancel()
        connectionStateTask?.cancel()
    }

    // MARK: Connection

    public func connect() async {
        switch connectionState {
        case .connecting, .connected:
            return
        case .disconnected, .unavailable:
            break
        }
        connectionState = .connecting
        let connection = makeConnection(savedHost)
        self.connection = connection

        let hello = HelloRequest(
            deviceID: savedHost.deviceID,
            deviceToken: savedHost.deviceToken,
            clientName: clientName,
            clientVersion: clientVersion,
            protocolVersion: RemoteProtocol.version,
            capabilities: RemoteProtocol.capabilities
        )
        do {
            let info = try await connection.connect(hello: hello)
            connectionState = .connected(info)
            await observe(connection)
            await reconcilePendingOperations()
            await refreshInventory()
        } catch let error as RemoteClientError {
            self.connection = nil
            markStale()
            connectionState = .unavailable(message: error.userMessage)
        } catch {
            self.connection = nil
            markStale()
            connectionState = .unavailable(message: String(describing: error))
        }
    }

    /// Confirms the Mac still answers on the current connection. A suspended iPhone can lose its
    /// socket without any close event, so a silent host is treated as disconnected and the caller
    /// reconnects instead of letting every later request time out.
    public func verifyConnection(timeout: Duration = .seconds(3)) async -> Bool {
        guard case .connected = connectionState, let connection else { return false }
        if await connection.probe(timeout: timeout) { return true }
        disconnect()
        connectionState = .unavailable(message: "The Mac stopped answering. Reconnect to continue.")
        return false
    }

    public func disconnect() {
        eventsTask?.cancel()
        connectionStateTask?.cancel()
        eventsTask = nil
        connectionStateTask = nil
        if let connection {
            Task { await connection.close() }
        }
        connection = nil
        markStale()
        connectionState = .disconnected
    }

    // MARK: Inventory

    public func refreshInventory() async {
        guard let connection else { return }
        if refreshInFlight {
            refreshRequestedAgain = true
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }

        repeat {
            refreshRequestedAgain = false
            do {
                let result = try await connection.request(.listInventory(ListInventoryRequest()))
                if case .inventory(let snapshot) = result {
                    inventory = snapshot
                    inventoryIsStale = false
                }
            } catch {
                markStale()
                return
            }
        } while refreshRequestedAgain
    }

    // MARK: Operations

    /// Records the operation key before sending so a lost response can be reconciled later; the
    /// key is cleared as soon as the host reports the operation completed or failed.
    public func launch(_ request: LaunchOperationRequest) async throws -> OperationStatus {
        guard let connection else { throw RemoteClientError.disconnected }
        journal.record(request.operationKey)
        do {
            let result = try await connection.request(.launch(request))
            guard case .operation(let status) = result else {
                throw RemoteClientError.invalidResponse("launch returned \(result.kind)")
            }
            settle(status)
            return status
        } catch RemoteClientError.remote(let error) {
            // The host answered: the operation was rejected and is not running.
            journal.remove(request.operationKey)
            throw RemoteClientError.remote(error)
        }
    }

    /// Asks the host about every journaled key. Called after each connect.
    public func reconcilePendingOperations() async {
        guard let connection else { return }
        for key in journal.pendingKeys() {
            do {
                let result = try await connection.request(.getOperationStatus(OperationStatusRequest(operationKey: key)))
                if case .operation(let status) = result {
                    settle(status)
                }
            } catch RemoteClientError.remote(let error) where !error.retryable {
                // The host does not know this operation; there is nothing left to resolve.
                journal.remove(key)
            } catch {
                // Keep the key for the next reconnect.
            }
        }
    }

    public func sessionProgress(sessionID: UUID) async throws -> SessionProgressPanel {
        guard case .connected(let host) = connectionState, let connection else { throw RemoteClientError.disconnected }
        guard host.capabilities.contains("progress.v1") else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on your Mac to view progress on this device.")
        }
        let result = try await connection.request(.getSessionProgress(SessionProgressRequest(sessionID: sessionID)))
        guard case .sessionProgress(let panel) = result, panel.sessionID == sessionID else {
            throw RemoteClientError.invalidResponse("The Mac returned progress for a different session.")
        }
        return panel
    }

    public func sessionDocuments(sessionID: UUID) async throws -> SessionDocumentList {
        guard case .connected(let host) = connectionState, let connection else { throw RemoteClientError.disconnected }
        guard host.capabilities.contains(RemoteProtocol.documents) else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on your Mac to read documents on this device.")
        }
        let result = try await connection.request(.listSessionDocuments(SessionDocumentsRequest(sessionID: sessionID)))
        guard case .sessionDocuments(let list) = result, list.sessionID == sessionID else {
            throw RemoteClientError.invalidResponse("The Mac returned documents for a different session.")
        }
        return list
    }

    public func readDocument(sessionID: UUID?, path: String, knownVersion: String?) async throws -> DocumentContent {
        guard case .connected(let host) = connectionState, let connection else { throw RemoteClientError.disconnected }
        guard host.capabilities.contains(RemoteProtocol.documents) else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on your Mac to read documents on this device.")
        }
        let result = try await connection.request(.readDocument(DocumentReadRequest(sessionID: sessionID, path: path, knownVersion: knownVersion)))
        guard case .document(let content) = result else {
            throw RemoteClientError.invalidResponse("The Mac returned an unexpected response for this document.")
        }
        return content
    }

    /// Downloads a binary file such as an image chunk by chunk. The result covers the whole file at offset 0;
    /// its `data` is nil when the file still has `knownVersion`. A file rewritten mid-download starts over.
    public func readDocumentData(sessionID: UUID?, path: String, knownVersion: String?) async throws -> DocumentChunk {
        guard case .connected(let host) = connectionState, let connection else { throw RemoteClientError.disconnected }
        guard host.capabilities.contains(RemoteProtocol.documentChunks) else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on your Mac to preview images on this device.")
        }
        func chunk(at offset: Int64, known: String?) async throws -> DocumentChunk {
            let result = try await connection.request(.readDocumentChunk(DocumentChunkRequest(sessionID: sessionID, path: path, offset: offset, knownVersion: known)))
            guard case .documentChunk(let chunk) = result, chunk.offset == offset else {
                throw RemoteClientError.invalidResponse("The Mac returned an unexpected response for this file.")
            }
            return chunk
        }
        for _ in 0..<3 {
            let first = try await chunk(at: 0, known: knownVersion)
            guard var data = first.data else { return first }
            var restarted = false
            while Int64(data.count) < first.size {
                try Task.checkCancellation()
                let next: DocumentChunk
                do {
                    next = try await chunk(at: Int64(data.count), known: nil)
                } catch RemoteClientError.remote(let error) where error.code == "document_changed" {
                    // The file shrank below what was already read, or changed during this chunk's read.
                    restarted = true; break
                }
                guard next.version == first.version, let bytes = next.data, !bytes.isEmpty else { restarted = true; break }
                data.append(bytes)
            }
            if restarted { continue }
            var whole = first
            whole.data = data
            return whole
        }
        throw RemoteClientError.invalidResponse("The file kept changing while it was being read. Try again.")
    }

    public func worktreeBranches(projectID: UUID, folderID: UUID) async throws -> [WorktreeBranchOption] {
        guard case .connected(let host) = connectionState, let connection else { throw RemoteClientError.disconnected }
        guard host.capabilities.contains("worktree.branches.v1") else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on your Mac to choose an existing branch.")
        }
        let result = try await connection.request(.listWorktreeBranches(ListWorktreeBranchesRequest(projectID: projectID, folderID: folderID)))
        guard case .worktreeBranches(let branches) = result else {
            throw RemoteClientError.invalidResponse("The Mac did not return a branch list.")
        }
        return branches
    }

    public func previewWorktree(projectID: UUID, folderID: UUID, branch: String) async throws -> String {
        guard let connection else { throw RemoteClientError.disconnected }
        let request = PreviewWorktreeRequest(projectID: projectID, folderID: folderID, branch: branch)
        let result = try await connection.request(.previewWorktreeDestination(request))
        guard case .worktreeDestination(let preview) = result else {
            throw RemoteClientError.invalidResponse("previewWorktreeDestination returned \(result.kind)")
        }
        return preview.path
    }

    /// The ticket that pasted launch-form text names, with the repository's branch template applied;
    /// nil when it names none or the Mac predates `ticket.resolve.v1`.
    public func resolveTicket(projectID: UUID, folderID: UUID, text: String) async throws -> TicketSuggestion? {
        guard isTicketResolutionSupported else { return nil }
        guard let connection else { throw RemoteClientError.disconnected }
        let result = try await connection.request(.resolveTicket(ResolveTicketRequest(projectID: projectID, folderID: folderID, text: text)))
        guard case .ticketSuggestion(let suggestion) = result else {
            throw RemoteClientError.invalidResponse("resolveTicket returned \(result.kind)")
        }
        return suggestion.ticket
    }

    /// Adds a group to the project (or reopens the one with this name) and refreshes the inventory so pickers list it.
    public func createGroup(projectID: UUID, name: String) async throws -> GroupSummary {
        guard let connection else { throw RemoteClientError.disconnected }
        let result = try await connection.request(.createGroup(CreateGroupRequest(projectID: projectID, name: name)))
        guard case .group(let group) = result else {
            throw RemoteClientError.invalidResponse("createGroup returned \(result.kind)")
        }
        await refreshInventory()
        return group
    }

    /// What suspending a project would do, with each agent's conversation checked on the Mac.
    public func suspendPlan(projectID: UUID) async throws -> RemoteSuspendPlan {
        let connection = try suspensionConnection()
        // The Mac reads each agent's transcripts before answering.
        let result = try await connection.request(.getSuspendPlan(SuspendPlanRequest(projectID: projectID)), timeout: .seconds(30))
        guard case .suspendPlan(let plan) = result else {
            throw RemoteClientError.invalidResponse("getSuspendPlan returned \(result.kind)")
        }
        return plan
    }

    /// Suspends a project as `plan` described, then refreshes the inventory. Each agent gets a grace
    /// period to quit, so the request waits longer than usual; the inventory is refreshed even when
    /// it fails or times out, since the Mac may have stopped some sessions or still be working.
    public func suspendProject(_ plan: RemoteSuspendPlan) async throws {
        let connection = try suspensionConnection()
        let request = SuspendProjectRequest(projectID: plan.projectID, interruptBusy: !plan.busyAgents.isEmpty, endMissingCheckouts: plan.missingCheckouts.map(\.sessionID))
        let timeout = Duration.seconds(30 + plan.agents.count * 10 + plan.shells.count * 5)
        let result: RemoteResult
        do { result = try await connection.request(.suspendProject(request), timeout: timeout) }
        catch { await refreshInventory(); throw error }
        await refreshInventory()
        guard case .ack = result else {
            throw RemoteClientError.invalidResponse("suspendProject returned \(result.kind)")
        }
    }

    /// Resumes `sessionIDs` and ends the project's other suspended sessions, then refreshes the inventory.
    /// `shownSessionIDs` are all the suspended sessions the user chose from; the Mac refuses if they changed.
    public func restoreProject(_ projectID: UUID, sessionIDs: [UUID], shownSessionIDs: [UUID]? = nil) async throws -> RemoteRestoreResult {
        let connection = try suspensionConnection()
        let timeout = Duration.seconds(60 + sessionIDs.count * 30)
        let result: RemoteResult
        do { result = try await connection.request(.restoreProject(RestoreProjectRequest(projectID: projectID, sessionIDs: sessionIDs, shownSessionIDs: shownSessionIDs)), timeout: timeout) }
        catch { await refreshInventory(); throw error }
        await refreshInventory()
        guard case .restoreResult(let restored) = result else {
            throw RemoteClientError.invalidResponse("restoreProject returned \(result.kind)")
        }
        return restored
    }

    private func suspensionConnection() throws -> RemoteConnection {
        guard isProjectSuspensionSupported else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on the Mac to suspend projects remotely.")
        }
        guard let connection else { throw RemoteClientError.disconnected }
        return connection
    }

    /// Stops a live session and refreshes the inventory so the list shows it stopped.
    public func stopSession(_ sessionID: UUID, force: Bool = false) async throws {
        guard isSessionStopSupported else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on the host to stop sessions remotely.")
        }
        guard let connection else { throw RemoteClientError.disconnected }
        let result = try await connection.request(.stopSession(StopSessionRequest(sessionID: sessionID, force: force)))
        guard case .ack = result else {
            throw RemoteClientError.invalidResponse("stopSession returned \(result.kind)")
        }
        await refreshInventory()
    }

    public func setKeepAwakeSettings(_ settings: KeepAwakeSettings) async throws {
        let status = try await requestKeepAwake(.setKeepAwakeSettings(settings))
        updateKeepAwake(status)
    }

    public func setKeepAwakeTimer(until: Date?) async throws {
        let status = try await requestKeepAwake(.setKeepAwakeTimer(KeepAwakeTimerRequest(until: until)))
        updateKeepAwake(status)
    }

    /// Sends a file to the Mac in chunks and returns where the Mac saved it. `progress` receives
    /// the fraction the Mac has confirmed. A chunk whose response is lost is sent once more.
    public func uploadFile(_ data: Data, filename: String, progress: @MainActor (Double) -> Void = { _ in }) async throws -> String {
        guard isFileUploadSupported, let connection else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on your Mac to send files from this device.")
        }
        guard !data.isEmpty, Int64(data.count) <= UploadFileChunkRequest.maxTotalBytes else {
            throw RemoteClientError.invalidResponse("Files must be between 1 byte and \(UploadFileChunkRequest.maxTotalBytes / 1_048_576) MB.")
        }
        let uploadID = UUID(), total = Int64(data.count)
        var offset = 0
        while true {
            let end = min(offset + UploadFileChunkRequest.chunkBytes, data.count)
            let chunk = UploadFileChunkRequest(uploadID: uploadID, filename: filename, totalBytes: total, offset: Int64(offset), data: data.subdata(in: offset..<end))
            let result: RemoteResult
            do { result = try await connection.request(.uploadFileChunk(chunk)) }
            catch RemoteClientError.timeout { result = try await connection.request(.uploadFileChunk(chunk)) }
            guard case .uploadedFile(let status) = result, status.uploadID == uploadID else {
                throw RemoteClientError.invalidResponse("uploadFileChunk returned \(result.kind)")
            }
            progress(Double(status.receivedBytes) / Double(total))
            if let path = status.path { return path }
            guard status.receivedBytes == Int64(end) else {
                throw RemoteClientError.invalidResponse("The Mac lost part of the file. Send it again.")
            }
            offset = end
        }
    }

    // MARK: Terminals

    /// A controller bound to this host's connection. The caller retains it and calls `attach`.
    public func makeTerminal(sessionID: UUID, adapter: any TerminalEngineAdapter) throws -> RemoteSessionController {
        guard let connection else { throw RemoteClientError.disconnected }
        return RemoteSessionController(sessionID: sessionID, connection: connection, adapter: adapter)
    }

    // MARK: Private

    private func requestKeepAwake(_ operation: RemoteOperation) async throws -> KeepAwakeStatus {
        guard case .connected(let host) = connectionState, let connection else { throw RemoteClientError.disconnected }
        guard host.capabilities.contains(RemoteProtocol.keepAwake) else {
            throw RemoteClientError.invalidResponse("Update Chauffeur on your Mac to control Keep Awake.")
        }
        let result = try await connection.request(operation)
        guard case .keepAwake(let status) = result else {
            throw RemoteClientError.invalidResponse("The Mac did not return Keep Awake status.")
        }
        return status
    }

    private func updateKeepAwake(_ status: KeepAwakeStatus) {
        inventory?.keepAwake = status
        // A partial status response cannot certify that cached sessions are current.
    }

    private func observe(_ connection: RemoteConnection) async {
        eventsTask?.cancel()
        connectionStateTask?.cancel()

        let events = await connection.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handleEvent(event)
            }
        }

        let states = await connection.stateChanges()
        connectionStateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.handleConnectionState(state, of: connection)
            }
        }
    }

    private func handleEvent(_ event: RemoteEvent) async {
        switch event {
        case .inventoryChanged:
            await refreshInventory()
        case .sessionChanged(let summary):
            guard var snapshot = inventory else { return }
            if let index = snapshot.sessions.firstIndex(where: { $0.id == summary.id }) {
                snapshot.sessions[index] = summary
            } else {
                snapshot.sessions.append(summary)
            }
            inventory = snapshot
        case .operationUpdated(let status):
            settle(status)
        case .accessRevoked:
            markStale()
            connectionState = .unavailable(message: RemoteClientError.unauthorized("Access revoked").userMessage)
        case .attachmentEnded:
            break
        }
    }

    private func handleConnectionState(_ state: RemoteConnection.State, of connection: RemoteConnection) {
        guard self.connection === connection else { return }
        switch state {
        case .failed(let error):
            self.connection = nil
            markStale()
            connectionState = .unavailable(message: error.userMessage)
        case .closed:
            self.connection = nil
            markStale()
            if case .unavailable = connectionState { return }
            connectionState = .disconnected
        case .idle, .connecting, .ready:
            break
        }
    }

    private func settle(_ status: OperationStatus) {
        switch status.phase {
        case .completed, .failed:
            journal.remove(status.operationKey)
        case .creatingWorktree, .worktreeReady, .launching:
            break
        }
    }

    private func markStale() {
        if inventory != nil {
            inventoryIsStale = true
        }
    }
}
