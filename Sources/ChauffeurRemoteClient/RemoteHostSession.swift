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

    public func previewWorktree(projectID: UUID, folderID: UUID, branch: String) async throws -> String {
        guard let connection else { throw RemoteClientError.disconnected }
        let request = PreviewWorktreeRequest(projectID: projectID, folderID: folderID, branch: branch)
        let result = try await connection.request(.previewWorktreeDestination(request))
        guard case .worktreeDestination(let preview) = result else {
            throw RemoteClientError.invalidResponse("previewWorktreeDestination returned \(result.kind)")
        }
        return preview.path
    }

    // MARK: Terminals

    /// A controller bound to this host's connection. The caller retains it and calls `attach`.
    public func makeTerminal(sessionID: UUID, adapter: any TerminalEngineAdapter) throws -> RemoteSessionController {
        guard let connection else { throw RemoteClientError.disconnected }
        return RemoteSessionController(sessionID: sessionID, connection: connection, adapter: adapter)
    }

    // MARK: Private

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
