import Foundation
import Observation
import UIKit
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient
import ChauffeurTerminalInterface
import ChauffeurTerminalTesting
import ChauffeurTerminalSwiftTerm

/// Where a launch will run. `newWorktree` collects branch/base on the Launch screen.
struct LaunchLocation: Hashable {
    enum Checkout: Hashable {
        /// An existing checkout, identified by its path (`CheckoutSummary.id`).
        case existing(path: String)
        case newWorktree
    }

    var projectID: UUID
    var folderID: UUID
    var checkout: Checkout
}

enum MobileRoute: Hashable {
    case sessions
    case terminal
    /// `projectID` preselects the project ("Launch here" from Sessions).
    case location(projectID: UUID?)
    case launch(LaunchLocation)
}

/// What the Launch screen shows after `MobileAppModel.launch` returns.
enum LaunchOutcome {
    case launched(sessionID: UUID)
    /// `worktreeCreated` means the Mac kept a worktree for this operation key; a retry launches in it.
    case failed(message: String, worktreeCreated: Bool)
}

/// The app coordinator: one saved Mac, its `RemoteHostSession`, the navigation path, and the
/// terminal tabs open on this phone. Views read connection state and inventory through here.
@MainActor
@Observable
final class MobileAppModel {
    /// The Mac runtime's main port for this build; pairing listens on the next port.
    static let defaultPort: Int = {
        #if DEBUG
        51848
        #else
        51847
        #endif
    }()

    static let keychainService: String = {
        #if DEBUG
        "dev.cliq.chauffeur.mobile.debug"
        #else
        "dev.cliq.chauffeur.mobile"
        #endif
    }()

    private(set) var savedHost: SavedHost?
    private(set) var session: RemoteHostSession?
    /// Pairing and credential errors; connection errors come from `session.connectionState`.
    var connectError: String?
    private(set) var isPairing = false
    var path: [MobileRoute] = []
    /// Session IDs open as tabs on this device only.
    private(set) var openTabs: [UUID] = []
    private(set) var selectedTab: UUID?
    /// One controller per open tab, created lazily once the session is connected.
    private(set) var terminals: [UUID: RemoteSessionController] = [:]

    @ObservationIgnored let credentials: any CredentialStore
    @ObservationIgnored let makeTerminalAdapter: @MainActor () -> any TerminalEngineAdapter
    @ObservationIgnored private let journal: any PendingOperationJournal
    @ObservationIgnored private var adapters: [UUID: any TerminalEngineAdapter] = [:]
    @ObservationIgnored private var previewInventory: InventorySnapshot?
    @ObservationIgnored private var previewConnectionState: HostConnectionState?

    init(
        credentials: any CredentialStore = FallbackCredentialStore(
            primary: KeychainCredentialStore(service: MobileAppModel.keychainService),
            fallback: FileCredentialStore()
        ),
        journal: any PendingOperationJournal = UserDefaultsOperationJournal(),
        makeTerminalAdapter: @escaping @MainActor () -> any TerminalEngineAdapter
    ) {
        self.credentials = credentials
        self.journal = journal
        self.makeTerminalAdapter = makeTerminalAdapter
        do {
            savedHost = try credentials.load()
        } catch CredentialStoreError.keychain(let status) {
            connectError = "The keychain is unavailable (status \(String(status))). Pairing will work but may not be remembered."
        } catch {
            connectError = "The saved Mac could not be read. Pair again."
        }
    }

    /// The app's engine choice. `--fake-terminal` forces the fake engine for UI runs without SwiftTerm.
    static func defaultTerminalAdapterFactory(
        arguments: [String] = CommandLine.arguments
    ) -> @MainActor () -> any TerminalEngineAdapter {
        if arguments.contains("--fake-terminal") {
            return { FakeTerminalEngineAdapter() }
        }
        return { SwiftTermAdapter(appearance: TerminalAppearance(fontSize: 13, scrollbackLines: 5_000)) }
    }

    // MARK: - State read by the screens

    var connectionState: HostConnectionState {
        session?.connectionState ?? previewConnectionState ?? .disconnected
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var isConnecting: Bool {
        connectionState == .connecting
    }

    var inventory: InventorySnapshot? {
        session?.inventory ?? previewInventory
    }

    /// True while the inventory shown may no longer match the Mac.
    var inventoryIsStale: Bool {
        session?.inventoryIsStale ?? false
    }

    var hostName: String? {
        if case .connected(let info) = connectionState { return info.hostName }
        return inventory?.hostName ?? savedHost?.name
    }

    // MARK: - Connection

    /// Connects to the saved Mac. `RemoteHostSession.connect()` reconciles pending launches and
    /// refreshes the inventory before returning.
    func connect() async {
        guard let savedHost else {
            connectError = "Pair this iPhone with your Mac first."
            return
        }
        connectError = nil
        let session = self.session ?? RemoteHostSession(host: savedHost, journal: journal)
        self.session = session
        let wasConnected = isConnected
        await session.connect()
        guard case .connected = session.connectionState else { return }
        if !wasConnected {
            // Controllers are bound to the previous connection; rebuild them on the new one.
            terminals.removeAll()
        }
        if path.isEmpty {
            path = [.sessions]
        }
        await attachSelectedTerminalIfNeeded()
    }

    /// Pairs with the code shown on the Mac, saves the result, and connects.
    func pair(host: String, port: Int, code: String) async {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectError = "Enter your Mac's address."
            return
        }
        isPairing = true
        defer { isPairing = false }
        connectError = nil
        do {
            let paired = try await PairingClient.pair(
                host: trimmed,
                pairingPort: port + 1,
                code: code,
                deviceName: UIDevice.current.name
            )
            try credentials.save(paired)
            replaceHost(with: paired)
            await connect()
        } catch let error as RemoteClientError {
            connectError = error.userMessage
        } catch {
            connectError = String(describing: error)
        }
    }

    /// Removes the saved Mac and its credentials; the Mac keeps its own device record.
    func forget() {
        session?.disconnect()
        tearDownTerminals()
        session = nil
        savedHost = nil
        path = []
        do {
            try credentials.clear()
            connectError = nil
        } catch {
            connectError = "The saved Mac could not be removed: \(error)"
        }
    }

    func disconnect() {
        session?.disconnect()
    }

    func refreshInventory() async {
        await session?.refreshInventory()
    }

    // MARK: - App lifecycle

    /// Detaches the visible terminal so the Mac can hand it to another client; the connection stays.
    func handleBackground() {
        guard let id = selectedTab, let controller = terminals[id] else { return }
        Task { await controller.detach() }
    }

    /// Reconnects if the connection dropped, then restores the visible terminal: a controller we
    /// detached ourselves is attached again; one that lost its stream reattaches through
    /// `handleForeground()`; one that lost control stays put until the user takes control.
    func handleForeground() async {
        guard session != nil else { return }
        switch connectionState {
        case .connecting:
            return
        case .disconnected, .unavailable:
            await connect()
            return
        case .connected:
            break
        }
        guard let id = selectedTab, let controller = terminals[id] else { return }
        await controller.handleForeground()
        if case .idle = controller.state, path.contains(.terminal) {
            await controller.attach(takeControl: false)
        }
    }

    // MARK: - Tabs

    func openSession(_ id: UUID) {
        if !openTabs.contains(id) {
            openTabs.append(id)
        }
        if path.last != .terminal {
            path = [.sessions, .terminal]
        }
        selectTab(id)
    }

    /// Switching detaches the previous tab and attaches the new one; processes keep running.
    func selectTab(_ id: UUID) {
        guard selectedTab != id else { return }
        let previous = selectedTab.flatMap { terminals[$0] }
        selectedTab = id
        Task {
            if let previous {
                await previous.detach()
            }
            await attachSelectedTerminalIfNeeded()
        }
    }

    func closeTab(_ id: UUID) {
        guard let index = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: index)
        let controller = terminals.removeValue(forKey: id)
        let adapter = adapters.removeValue(forKey: id)
        Task {
            await controller?.detach()
            adapter?.dispose()
        }
        if selectedTab == id {
            selectedTab = nil
            if let next = openTabs.indices.contains(index) ? openTabs[index] : openTabs.last {
                selectTab(next)
            }
        }
    }

    // MARK: - Terminals

    /// The engine adapter for a tab. Safe to call from a view body: it never touches observed state.
    func adapter(for sessionID: UUID) -> any TerminalEngineAdapter {
        if let adapter = adapters[sessionID] {
            return adapter
        }
        let adapter = makeTerminalAdapter()
        adapters[sessionID] = adapter
        return adapter
    }

    /// The controller for a tab, created on the current connection. Nil while disconnected.
    func terminal(for sessionID: UUID) -> RemoteSessionController? {
        if let existing = terminals[sessionID] {
            return existing
        }
        guard let session, isConnected else { return nil }
        let adapter = adapter(for: sessionID)
        guard let controller = try? session.makeTerminal(sessionID: sessionID, adapter: adapter) else { return nil }
        controller.onClipboardCopy = { text in
            UIPasteboard.general.string = text
        }
        controller.onOpenLink = { link in
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }
        terminals[sessionID] = controller
        return controller
    }

    /// Attaches the selected tab when the terminal screen is open and the tab is not attached yet.
    func attachSelectedTerminalIfNeeded() async {
        guard path.contains(.terminal), let id = selectedTab, let controller = terminal(for: id) else { return }
        if case .idle = controller.state {
            await controller.attach(takeControl: false)
        }
        adapter(for: id).focus()
    }

    /// "Reconnect" on the terminal banner: restores the connection first when it dropped.
    func retryTerminal(_ sessionID: UUID) async {
        if !isConnected {
            await connect()
        }
        guard isConnected, let controller = terminal(for: sessionID) else { return }
        switch controller.state {
        case .idle, .disconnected:
            await controller.attach(takeControl: false)
        case .attaching, .attached, .controlLost, .ended:
            break
        }
    }

    /// Explicit user action only.
    func takeControl(of sessionID: UUID) async {
        await terminals[sessionID]?.takeControl()
    }

    // MARK: - Launch

    func previewWorktree(projectID: UUID, folderID: UUID, branch: String) async throws -> String {
        guard let session else { throw RemoteClientError.disconnected }
        return try await session.previewWorktree(projectID: projectID, folderID: folderID, branch: branch)
    }

    /// Sends the launch and, on completion, opens the new session as the selected tab.
    func launch(_ request: LaunchOperationRequest) async -> LaunchOutcome {
        guard let session, isConnected else {
            return .failed(message: RemoteClientError.disconnected.userMessage, worktreeCreated: false)
        }
        do {
            let status = try await session.launch(request)
            switch status.phase {
            case .completed:
                guard let sessionID = status.sessionID else {
                    return .failed(message: "The Mac reported success without a session.", worktreeCreated: status.worktreeID != nil)
                }
                await session.refreshInventory()
                openSession(sessionID)
                return .launched(sessionID: sessionID)
            case .failed:
                return .failed(message: status.error?.message ?? "The launch failed.", worktreeCreated: status.worktreeID != nil)
            case .creatingWorktree, .worktreeReady, .launching:
                return .failed(message: "The launch is still running on the Mac. Retry to check its result.", worktreeCreated: status.worktreeID != nil)
            }
        } catch let error as RemoteClientError {
            return .failed(message: error.userMessage, worktreeCreated: false)
        } catch {
            return .failed(message: String(describing: error), worktreeCreated: false)
        }
    }

    // MARK: - Lookups

    /// Sessions the runtime reports as live, including ones waiting for input.
    var liveSessions: [SessionSummary] {
        inventory?.sessions.filter { $0.state.isLive } ?? []
    }

    func session(_ id: UUID) -> SessionSummary? {
        inventory?.session(id)
    }

    var selectedSession: SessionSummary? {
        selectedTab.flatMap(session)
    }

    func location(of session: SessionSummary) -> LaunchLocation {
        LaunchLocation(projectID: session.projectID, folderID: session.folderID, checkout: .existing(path: session.checkoutPath))
    }

    func describe(_ location: LaunchLocation) -> String {
        let project = inventory?.project(location.projectID)?.name ?? "Project"
        switch location.checkout {
        case .existing(let path):
            return "\(project) / \(inventory?.checkout(path: path)?.branch ?? path)"
        case .newWorktree:
            return "\(project) / new worktree"
        }
    }

    // MARK: - Private

    private func replaceHost(with host: SavedHost) {
        session?.disconnect()
        tearDownTerminals()
        session = nil
        savedHost = host
    }

    private func tearDownTerminals() {
        let controllers = Array(terminals.values)
        let engines = Array(adapters.values)
        terminals.removeAll()
        adapters.removeAll()
        openTabs.removeAll()
        selectedTab = nil
        Task {
            for controller in controllers {
                await controller.detach()
            }
            for engine in engines {
                engine.dispose()
            }
        }
    }

    // MARK: - Preview fixture

    /// A model for `#Preview`s: a saved Mac with fixture inventory and no live connection.
    static func preview(connected: Bool = true) -> MobileAppModel {
        let host = fixtureHost()
        let model = MobileAppModel(
            credentials: InMemoryCredentialStore(host: host),
            journal: InMemoryOperationJournal(),
            makeTerminalAdapter: { FakeTerminalEngineAdapter() }
        )
        model.previewInventory = fixtureInventory(hostName: host.name)
        if connected {
            model.previewConnectionState = .connected(HostInfo(
                hostID: host.hostID,
                hostName: host.name,
                runtimeVersion: "0.1",
                build: "debug",
                protocolVersion: RemoteProtocol.version,
                capabilities: RemoteProtocol.capabilities
            ))
            model.path = [.sessions]
        }
        let sessions = model.inventory?.sessions ?? []
        model.openTabs = sessions.prefix(2).map(\.id)
        model.selectedTab = model.openTabs.first
        return model
    }

    static func fixtureHost() -> SavedHost {
        SavedHost(
            hostID: UUID(),
            name: "Leo's Mac",
            host: "leos-mac.local",
            port: defaultPort,
            remoteAccessKey: Data(repeating: 0x42, count: 32),
            deviceID: UUID(),
            deviceToken: "preview-token",
            pairedAt: Date()
        )
    }

    /// Two projects (one without sessions), three sessions across two checkouts.
    static func fixtureInventory(hostName: String) -> InventorySnapshot {
        let chauffeurProject = UUID()
        let chauffeurFolder = UUID()
        let mobileWorktree = UUID()
        let notesProject = UUID()
        let notesFolder = UUID()
        let mainPath = "/Users/leo/Chauffeur"
        let mobilePath = "/Users/leo/Chauffeur/.worktrees/feature-mobile"
        let notesPath = "/Users/leo/Documents/notes"
        let now = Date()

        let codexPreset = PresetSummary(id: UUID(), name: "Codex · Personal", kind: .codex)
        let claudePreset = PresetSummary(id: UUID(), name: "Claude · Personal", kind: .claude)
        let defaultGroup = GroupSummary(id: UUID(), name: "Default", isDefault: true)
        let reviewGroup = GroupSummary(id: UUID(), name: "Review")

        return InventorySnapshot(
            revision: 1,
            hostName: hostName,
            projects: [
                ProjectSummary(
                    id: chauffeurProject,
                    name: "Chauffeur",
                    groups: [defaultGroup, reviewGroup],
                    presets: [codexPreset, claudePreset],
                    folders: [
                        FolderSummary(
                            id: chauffeurFolder,
                            name: "Chauffeur",
                            path: mainPath,
                            isRepository: true,
                            inventoryReady: true,
                            availability: .available,
                            checkouts: [
                                CheckoutSummary(kind: .main, branch: "main", path: mainPath, availability: .available),
                                CheckoutSummary(kind: .worktree, worktreeID: mobileWorktree, branch: "feature/mobile", path: mobilePath, availability: .available, managed: true)
                            ]
                        )
                    ]
                ),
                ProjectSummary(
                    id: notesProject,
                    name: "Notes",
                    groups: [GroupSummary(id: UUID(), name: "Default", isDefault: true)],
                    presets: [claudePreset],
                    folders: [
                        FolderSummary(
                            id: notesFolder,
                            name: "notes",
                            path: notesPath,
                            isRepository: false,
                            inventoryReady: true,
                            availability: .available,
                            checkouts: [
                                CheckoutSummary(kind: .main, branch: "folder", path: notesPath, availability: .available)
                            ]
                        )
                    ]
                )
            ],
            sessions: [
                SessionSummary(
                    id: UUID(), projectID: chauffeurProject, folderID: chauffeurFolder, worktreeID: mobileWorktree,
                    title: "Mobile remote", kind: .codex, state: .needsAttention, needsAttention: true,
                    branch: "feature/mobile", checkoutPath: mobilePath, attached: true, createdAt: now, updatedAt: now
                ),
                SessionSummary(
                    id: UUID(), projectID: chauffeurProject, folderID: chauffeurFolder, worktreeID: mobileWorktree,
                    title: "Review protocol", kind: .claude, state: .running,
                    branch: "feature/mobile", checkoutPath: mobilePath, createdAt: now, updatedAt: now
                ),
                SessionSummary(
                    id: UUID(), projectID: chauffeurProject, folderID: chauffeurFolder,
                    title: "Shell", kind: .shell, state: .running,
                    branch: "main", checkoutPath: mainPath, createdAt: now, updatedAt: now
                ),
                SessionSummary(
                    id: UUID(), projectID: chauffeurProject, folderID: chauffeurFolder,
                    title: "Old run", kind: .codex, state: .exited,
                    branch: "main", checkoutPath: mainPath, createdAt: now, updatedAt: now
                )
            ],
            generatedAt: now
        )
    }
}
