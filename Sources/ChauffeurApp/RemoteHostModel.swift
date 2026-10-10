import Foundation
import AppKit
import Observation
import ChauffeurCore
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient
import ChauffeurTerminalInterface

/// The servers this Mac is paired with, and one `RemoteHostModel` per server window. Pairing
/// and forgetting happen here; connecting, terminals and launches belong to each server's model.
@MainActor
@Observable
final class RemoteHostStore {
    /// Hosts are usually Release builds even when this app is a Debug build, so this does not
    /// follow the build. Pairing listens on the next port.
    static let defaultPort = RemoteProtocol.releasePort

    private(set) var savedHosts: [SavedHost] = []
    var error: String?
    private(set) var isPairing = false

    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let makeTerminalAdapter: @MainActor () -> any TerminalEngineAdapter
    @ObservationIgnored private var models: [UUID: RemoteHostModel] = [:]

    init(
        credentials: any CredentialStore = RemoteHostStore.defaultCredentials(),
        makeTerminalAdapter: @escaping @MainActor () -> any TerminalEngineAdapter
    ) {
        self.credentials = credentials
        self.makeTerminalAdapter = makeTerminalAdapter
        do { savedHosts = try credentials.loadAll() } catch { self.error = "Saved servers could not be read: \(error)" }
    }

    /// A 0600 file in this build's data root, also read (names only) by the menu bar helper. The
    /// Mac app has no data-protection keychain entitlement: saves fail with -34018 but reads only
    /// report "not found", so the keychain fallback the iPhone uses would never read it back.
    static func defaultCredentials() -> any CredentialStore {
        FileCredentialStore(url: RemoteHostListing.fileURL)
    }

    /// Main ports that leave room for the pairing port after them.
    static let validPorts = 1...65534

    func host(_ id: UUID) -> SavedHost? { savedHosts.first { $0.hostID == id } }

    /// The window model for a paired server; nil once it has been forgotten.
    func model(for id: UUID) -> RemoteHostModel? {
        if let model = models[id] { return model }
        guard let host = host(id) else { return nil }
        let model = RemoteHostModel(host: host, makeTerminalAdapter: makeTerminalAdapter)
        models[id] = model
        return model
    }

    /// Pairs with the code the server printed (`Scripts/linux/pair.sh`, or Settings ▸ Remote
    /// Access on a Mac) and saves it. Returns the server's ID, or nil with `error` set.
    func pair(host: String, port: Int, code: String) async -> UUID? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { error = "Enter the server's address."; return nil }
        guard Self.validPorts.contains(port) else { error = "Enter the server's main port, from 1 to 65534."; return nil }
        isPairing = true
        defer { isPairing = false }
        error = nil
        do {
            let paired = try await PairingClient.pair(host: host, pairingPort: port + 1, code: code, deviceName: Host.current().localizedName ?? "Mac")
            try credentials.save(paired)
            savedHosts = try credentials.loadAll()
            // A re-paired server keeps its ID but has a new device token.
            models[paired.hostID]?.replaceHost(paired)
            return paired.hostID
        } catch let error as RemoteClientError {
            self.error = error.userMessage
        } catch {
            self.error = String(describing: error)
        }
        return nil
    }

    /// Removes the server's credentials here; the server keeps its device record until revoked.
    func forget(_ id: UUID) {
        models.removeValue(forKey: id)?.disconnect()
        do {
            try credentials.remove(hostID: id)
            savedHosts.removeAll { $0.hostID == id }
        } catch {
            self.error = "The saved server could not be removed: \(error)"
        }
    }
}

/// The Mac app as a remote client of one paired Chauffeur runtime (a Linux server or another
/// Mac), the same way the iPhone app is: the connection, its inventory, and one terminal
/// controller per session opened in that server's window. Independent of `AppModel`, which only
/// ever talks to this Mac's runtime.
@MainActor
@Observable
final class RemoteHostModel {
    private(set) var savedHost: SavedHost
    private(set) var session: RemoteHostSession?
    /// Operation errors; connection errors come from `connectionState`.
    var error: String?
    /// The session whose terminal the window shows.
    private(set) var selectedSessionID: UUID?
    /// Sessions with a stop request in flight.
    private(set) var stopping: Set<UUID> = []
    private(set) var terminals: [UUID: RemoteSessionController] = [:]

    @ObservationIgnored private let makeTerminalAdapter: @MainActor () -> any TerminalEngineAdapter
    @ObservationIgnored private var adapters: [UUID: any TerminalEngineAdapter] = [:]
    /// The latest terminal transition; each one waits for the one before it.
    @ObservationIgnored private var transition: Task<Void, Never>?
    /// Counts connections replaced or closed; work queued under an earlier one does nothing.
    @ObservationIgnored private var lifetime = 0

    init(host: SavedHost, makeTerminalAdapter: @escaping @MainActor () -> any TerminalEngineAdapter) {
        self.savedHost = host
        self.makeTerminalAdapter = makeTerminalAdapter
    }

    /// New credentials for the same server: the old connection is closed.
    func replaceHost(_ host: SavedHost) {
        replaceSession()
        savedHost = host
    }

    // MARK: - State read by the window

    var connectionState: HostConnectionState { session?.connectionState ?? .disconnected }
    var isConnected: Bool { if case .connected = connectionState { return true } else { return false } }
    var isConnecting: Bool { connectionState == .connecting }
    var inventory: InventorySnapshot? { session?.inventory }
    var inventoryIsStale: Bool { session?.inventoryIsStale ?? false }
    var stopIsSupported: Bool { session?.isSessionStopSupported ?? false }
    var launchCoordinationIsSupported: Bool { session?.isLaunchCoordinationSupported ?? false }
    var groupCreationIsSupported: Bool { session?.isGroupCreationSupported ?? false }

    var hostName: String {
        if case .connected(let info) = connectionState { return info.hostName }
        return inventory?.hostName ?? savedHost.name
    }

    var connectionMessage: String? {
        switch connectionState {
        case .unavailable(let message): return message
        case .disconnected where session != nil: return "Disconnected from \(hostName)."
        default: return nil
        }
    }

    /// Live sessions grouped by project, in inventory order.
    var liveSessionsByProject: [(project: ProjectSummary, sessions: [SessionSummary])] {
        guard let inventory else { return [] }
        let live = inventory.sessions.filter { $0.state.isLive || $0.id == selectedSessionID }
        return inventory.projects.filter { !$0.archived }.compactMap { project in
            let sessions = live.filter { $0.projectID == project.id }
            return sessions.isEmpty ? nil : (project, sessions)
        }
    }

    var liveSessions: [SessionSummary] { inventory?.sessions.filter { $0.state.isLive } ?? [] }

    func session(_ id: UUID) -> SessionSummary? { inventory?.sessions.first { $0.id == id } }

    // MARK: - Connection

    func connect() async {
        await open(lifetime: lifetime)
        guard isConnected else { return }
        await serialized { _ in await self.applySelection() }
    }

    /// Opens the connection, unless the window closed it since `lifetime`. Controllers are bound
    /// to a connection, so a new one starts without them.
    private func open(lifetime: Int) async {
        guard lifetime == self.lifetime else { return }
        error = nil
        let session = self.session ?? RemoteHostSession(
            host: savedHost,
            journal: UserDefaultsOperationJournal(key: "chauffeur.remoteHost.pendingOperations.\(savedHost.hostID.uuidString)"),
            clientName: Host.current().localizedName ?? "Mac",
            clientVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        )
        self.session = session
        let wasConnected = isConnected
        await session.connect()
        guard lifetime == self.lifetime else { session.disconnect(); return }
        guard case .connected = session.connectionState else { return }
        if !wasConnected { terminals.removeAll() }
    }

    /// Detaches every terminal so other clients can control them, then closes the connection.
    func disconnect() {
        replaceSession()
    }

    func refreshInventory() async { await session?.refreshInventory() }

    // MARK: - Terminals

    func selectSession(_ id: UUID?) {
        guard id != selectedSessionID else { return }
        selectedSessionID = id
        Task { await serialized { _ in await self.applySelection() } }
    }

    /// Attaches the selected terminal if it isn't, for example once the connection returns.
    func refreshSelection() async {
        await serialized { _ in await self.applySelection() }
    }

    /// Drops the engines of sessions that are no longer live, except the selected one, so a
    /// long-lived window holds at most one terminal per live session.
    func pruneTerminals() {
        guard let inventory else { return }
        var keep = Set(inventory.sessions.filter { $0.state.isLive }.map(\.id))
        if let selectedSessionID { keep.insert(selectedSessionID) }
        for id in Set(terminals.keys).union(adapters.keys) where !keep.contains(id) { dropTerminal(id) }
    }

    /// The engine for a session. Safe from a view body: it never touches observed state.
    func adapter(for sessionID: UUID) -> any TerminalEngineAdapter {
        if let adapter = adapters[sessionID] { return adapter }
        let adapter = makeTerminalAdapter()
        adapters[sessionID] = adapter
        return adapter
    }

    func terminal(for sessionID: UUID) -> RemoteSessionController? {
        if let existing = terminals[sessionID] { return existing }
        guard let session, isConnected,
              let controller = try? session.makeTerminal(sessionID: sessionID, adapter: adapter(for: sessionID)) else { return nil }
        controller.onClipboardCopy = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        controller.onOpenLink = { link in
            guard let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }
        terminals[sessionID] = controller
        return controller
    }

    /// "Reconnect" on the terminal banner: restores the connection first when it dropped.
    func retryTerminal(_ sessionID: UUID) async {
        await serialized { lifetime in
            if !self.isConnected {
                await self.open(lifetime: lifetime)
            } else if let session = self.session, await !session.verifyConnection() {
                await self.open(lifetime: lifetime)
            }
            guard lifetime == self.lifetime, self.isConnected, let controller = self.terminal(for: sessionID) else { return }
            switch controller.state {
            case .idle, .disconnected: await controller.attach(takeControl: false)
            case .attaching, .attached, .controlLost, .ended: break
            }
        }
    }

    /// Explicit user action only; the other client can take it back the same way.
    func takeControl(of sessionID: UUID) async {
        await serialized { _ in
            guard let controller = self.terminal(for: sessionID) else { return }
            await controller.takeControl()
            if case .attached = controller.state { self.adapter(for: sessionID).focus() }
        }
    }

    /// Runs terminal transitions one at a time, so an attach still in flight completes before
    /// a newer selection detaches it, instead of attaching after it. Work queued before the
    /// connection was closed or replaced is skipped; `work` gets the lifetime it was queued in.
    private func serialized(_ work: @escaping @MainActor (_ lifetime: Int) async -> Void) async {
        let previous = transition, lifetime = self.lifetime
        let current = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, lifetime == self.lifetime else { return }
            await work(lifetime)
        }
        transition = current
        await current.value
    }

    /// Detaches every terminal but the selected one, then attaches that without taking
    /// control from another client. Processes keep running; only this window's view changes.
    private func applySelection() async {
        pruneTerminals()
        for (id, controller) in terminals where id != selectedSessionID {
            switch controller.state {
            case .attaching, .attached: await controller.detach()
            case .idle, .controlLost, .disconnected, .ended: break
            }
        }
        guard let id = selectedSessionID, session(id)?.state.isLive == true, let controller = terminal(for: id) else { return }
        if case .idle = controller.state { await controller.attach(takeControl: false) }
        if case .attached = controller.state, selectedSessionID == id { adapter(for: id).focus() }
    }

    // MARK: - Stop

    func stop(_ sessionID: UUID, force: Bool) async {
        guard let session, isConnected, stopping.insert(sessionID).inserted else { return }
        defer { stopping.remove(sessionID) }
        do {
            try await session.stopSession(sessionID, force: force)
            if self.session(sessionID)?.state.isLive != true { dropTerminal(sessionID) }
        } catch let error as RemoteClientError {
            self.error = error.userMessage
        } catch {
            self.error = String(describing: error)
        }
    }

    // MARK: - Launch

    func worktreeBranches(projectID: UUID, folderID: UUID) async throws -> [WorktreeBranchOption] {
        guard let session else { throw RemoteClientError.disconnected }
        return try await session.worktreeBranches(projectID: projectID, folderID: folderID)
    }

    func previewWorktree(projectID: UUID, folderID: UUID, branch: String) async throws -> String {
        guard let session else { throw RemoteClientError.disconnected }
        return try await session.previewWorktree(projectID: projectID, folderID: folderID, branch: branch)
    }

    func resolveTicket(projectID: UUID, folderID: UUID, text: String) async throws -> TicketSuggestion? {
        guard let session else { throw RemoteClientError.disconnected }
        return try await session.resolveTicket(projectID: projectID, folderID: folderID, text: text)
    }

    func createGroup(projectID: UUID, name: String) async throws -> GroupSummary {
        guard let session else { throw RemoteClientError.disconnected }
        return try await session.createGroup(projectID: projectID, name: name)
    }

    /// Sends the launch and, once it completes, shows the new session. Returns an error message on failure.
    func launch(_ request: LaunchOperationRequest) async -> (sessionID: UUID?, failure: String?, worktreeCreated: Bool) {
        guard let session, isConnected else { return (nil, RemoteClientError.disconnected.userMessage, false) }
        do {
            let status = try await session.launch(request)
            switch status.phase {
            case .completed:
                guard let sessionID = status.sessionID else { return (nil, "The server reported success without a session.", status.worktreeID != nil) }
                await session.refreshInventory()
                selectSession(sessionID)
                return (sessionID, nil, false)
            case .failed:
                return (nil, status.error?.message ?? "The launch failed.", status.worktreeID != nil)
            case .creatingWorktree, .worktreeReady, .launching:
                return (nil, "The launch is still running on the server. Retry to check its result.", status.worktreeID != nil)
            }
        } catch let error as RemoteClientError {
            return (nil, error.userMessage, false)
        } catch {
            return (nil, String(describing: error), false)
        }
    }

    // MARK: - Private

    private func dropTerminal(_ sessionID: UUID) {
        let controller = terminals.removeValue(forKey: sessionID)
        let adapter = adapters.removeValue(forKey: sessionID)
        Task {
            await controller?.detach()
            adapter?.dispose()
        }
    }

    private func replaceSession() {
        lifetime += 1
        transition?.cancel()
        transition = nil
        let controllers = Array(terminals.values)
        let engines = Array(adapters.values)
        let old = session
        terminals.removeAll()
        adapters.removeAll()
        selectedSessionID = nil
        session = nil
        Task {
            // Detach before closing so the server hands control back immediately.
            for controller in controllers { await controller.detach() }
            for engine in engines { engine.dispose() }
            old?.disconnect()
        }
    }
}
