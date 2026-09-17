import Foundation
import Observation
import ChauffeurTerminalInterface
import ChauffeurTerminalTesting
import ChauffeurTerminalSwiftTerm

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(hostName: String)
    case unavailable(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Who owns the selected session's terminal input.
enum TerminalControlState: Equatable {
    case controlledHere
    case controlledElsewhere(device: String)
}

struct SavedHost: Equatable {
    var name: String
    var host: String
    var port: Int
}

/// Where a launch will run. `newWorktree` collects branch/base on the Launch screen.
struct LaunchLocation: Hashable {
    enum Checkout: Hashable {
        case existing(UUID)
        case newWorktree
    }

    var projectID: UUID
    var folderID: UUID
    var checkout: Checkout
}

struct LaunchRequest {
    enum Kind: Equatable {
        case agent(presetID: UUID)
        case shell
    }

    var kind: Kind
    var title: String
    var initialTask: String
    var branch: String
    var baseRef: String
    var groupID: UUID?
}

enum MobileRoute: Hashable {
    case sessions
    case terminal
    /// `projectID` preselects the project ("Launch here" from Sessions).
    case location(projectID: UUID?)
    case launch(LaunchLocation)
}

@MainActor
@Observable
final class MobileAppModel {
    // TODO: replace with ChauffeurRemoteClient. Placeholder until the wire port is decided.
    static let defaultPort = 8787

    var connectionState: ConnectionState = .disconnected
    var inventory: InventorySnapshot?
    /// Set while the inventory shown is not live (disconnected or reconnecting).
    var staleSince: Date?
    /// Session IDs open as tabs on this device only.
    var openTabs: [UUID] = []
    var selectedTab: UUID?
    var path: [MobileRoute] = []
    var savedHost: SavedHost?
    var controlState: TerminalControlState = .controlledHere

    @ObservationIgnored
    let makeTerminalAdapter: () -> any TerminalEngineAdapter
    @ObservationIgnored
    private var adapters: [UUID: any TerminalEngineAdapter] = [:]

    init(makeTerminalAdapter: @escaping () -> any TerminalEngineAdapter) {
        self.makeTerminalAdapter = makeTerminalAdapter
    }

    /// The app's engine choice. `--fake-terminal` forces the fake engine for UI runs without SwiftTerm.
    static func defaultTerminalAdapterFactory(
        arguments: [String] = CommandLine.arguments
    ) -> () -> any TerminalEngineAdapter {
        if arguments.contains("--fake-terminal") {
            return { FakeTerminalEngineAdapter() }
        }
        // TODO: SwiftTermAdapter() once ChauffeurTerminalSwiftTerm has its implementation.
        return { FakeTerminalEngineAdapter() }
    }

    // MARK: - Intents (state only; no networking yet)

    func connect(host: String, port: Int) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectionState = .unavailable(message: "Enter your Mac's address.")
            return
        }
        connectionState = .connecting
        // TODO: replace with ChauffeurRemoteClient. For the scaffold, connecting succeeds immediately.
        let name = savedHost?.name ?? trimmed
        savedHost = SavedHost(name: name, host: trimmed, port: port)
        connectionState = .connected(hostName: name)
        staleSince = nil
        if inventory == nil {
            inventory = Self.fixtureInventory(hostName: name)
        }
        updateInputEnabled()
        if path.first != .sessions {
            path = [.sessions]
        }
    }

    func pair(code: String) {
        guard code.count == 10 else {
            connectionState = .unavailable(message: "Pairing codes have 10 characters.")
            return
        }
        // TODO: replace with ChauffeurRemoteClient pairing.
        connect(host: savedHost?.host ?? "leos-mac.local", port: savedHost?.port ?? Self.defaultPort)
    }

    func forgetSavedHost() {
        savedHost = nil
        connectionState = .disconnected
    }

    func disconnect() {
        connectionState = .disconnected
        if inventory != nil, staleSince == nil {
            staleSince = Date()
        }
        updateInputEnabled()
    }

    func reconnect() {
        guard let savedHost else {
            path = []
            return
        }
        connect(host: savedHost.host, port: savedHost.port)
    }

    func refresh() {
        guard connectionState.isConnected else { return }
        staleSince = nil
        inventory?.capturedAt = Date()
    }

    func openSession(_ id: UUID) {
        if !openTabs.contains(id) {
            openTabs.append(id)
        }
        selectedTab = id
        if path.last != .terminal {
            path = [.sessions, .terminal]
        }
    }

    func closeTab(_ id: UUID) {
        guard let index = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: index)
        adapters[id]?.dispose()
        adapters[id] = nil
        if selectedTab == id {
            selectedTab = openTabs.indices.contains(index) ? openTabs[index] : openTabs.last
        }
    }

    /// Creates the session locally so the flow is navigable; the runtime launch replaces this later.
    func launch(_ request: LaunchRequest, at location: LaunchLocation) {
        guard var inventory,
              let projectIndex = inventory.projects.firstIndex(where: { $0.id == location.projectID }),
              let folderIndex = inventory.projects[projectIndex].folders.firstIndex(where: { $0.id == location.folderID })
        else { return }

        var folder = inventory.projects[projectIndex].folders[folderIndex]
        let checkout: CheckoutSummary
        switch location.checkout {
        case .existing(let id):
            guard let existing = folder.checkouts.first(where: { $0.id == id }) else { return }
            checkout = existing
        case .newWorktree:
            checkout = CheckoutSummary(
                id: UUID(),
                kind: .worktree,
                branch: request.branch,
                path: folder.path + "-" + request.branch.replacingOccurrences(of: "/", with: "-")
            )
            folder.checkouts.append(checkout)
            inventory.projects[projectIndex].folders[folderIndex] = folder
        }

        let kind: SessionKind
        switch request.kind {
        case .agent(let presetID):
            kind = inventory.presets.first(where: { $0.id == presetID })?.kind ?? .codex
        case .shell:
            kind = .shell
        }
        let title = request.title.isEmpty ? kind.label : request.title
        let session = SessionSummary(
            id: UUID(),
            title: title,
            kind: kind,
            state: .running,
            needsAttention: false,
            projectID: location.projectID,
            folderID: location.folderID,
            checkoutID: checkout.id,
            branch: checkout.branch,
            isOpenOnMac: false
        )
        inventory.sessions.append(session)
        self.inventory = inventory
        openSession(session.id)
    }

    func takeControl() {
        controlState = .controlledHere
        updateInputEnabled()
    }

    // MARK: - Terminal adapters

    func terminalAdapter(for sessionID: UUID) -> any TerminalEngineAdapter {
        if let adapter = adapters[sessionID] {
            return adapter
        }
        let adapter = makeTerminalAdapter()
        adapter.configure(.default)
        if let fake = adapter as? FakeTerminalEngineAdapter, let session = inventory?.session(sessionID) {
            let path = inventory?.checkout(session.checkoutID)?.path ?? ""
            fake.feed(Data("\(session.kind.label)\n\(path)\n\nReady for your next instruction.\n\n› ".utf8))
        }
        adapters[sessionID] = adapter
        updateInputEnabled()
        return adapter
    }

    var isTerminalInputEnabled: Bool {
        connectionState.isConnected && controlState == .controlledHere
    }

    private func updateInputEnabled() {
        for adapter in adapters.values {
            adapter.setInputEnabled(isTerminalInputEnabled)
        }
    }

    // MARK: - Lookups

    var hostName: String? {
        if case .connected(let hostName) = connectionState { return hostName }
        return savedHost?.name
    }

    func session(_ id: UUID) -> SessionSummary? {
        inventory?.session(id)
    }

    var selectedSession: SessionSummary? {
        selectedTab.flatMap(session)
    }

    func location(of session: SessionSummary) -> LaunchLocation {
        LaunchLocation(projectID: session.projectID, folderID: session.folderID, checkout: .existing(session.checkoutID))
    }

    func describe(_ location: LaunchLocation) -> String {
        guard let inventory else { return "" }
        let project = inventory.project(location.projectID)?.name ?? "Project"
        switch location.checkout {
        case .existing(let id):
            return "\(project) / \(inventory.checkout(id)?.branch ?? "checkout")"
        case .newWorktree:
            return "\(project) / new worktree"
        }
    }

    // MARK: - Fixtures

    static func preview(connected: Bool = true) -> MobileAppModel {
        let model = MobileAppModel(makeTerminalAdapter: { FakeTerminalEngineAdapter() })
        model.savedHost = SavedHost(name: "Leo's Mac", host: "leos-mac.local", port: defaultPort)
        model.inventory = fixtureInventory(hostName: "Leo's Mac")
        if connected {
            model.connectionState = .connected(hostName: "Leo's Mac")
            model.path = [.sessions]
        }
        let sessions = model.inventory?.sessions ?? []
        model.openTabs = sessions.prefix(2).map(\.id)
        model.selectedTab = model.openTabs.first
        return model
    }

    /// Two projects (one without sessions), three sessions across two checkouts.
    static func fixtureInventory(hostName: String) -> InventorySnapshot {
        let chauffeurProject = UUID()
        let chauffeurFolder = UUID()
        let mainCheckout = UUID()
        let mobileCheckout = UUID()
        let notesProject = UUID()
        let notesFolder = UUID()
        let notesCheckout = UUID()

        let codexPreset = AgentPreset(id: UUID(), name: "Codex · Personal", kind: .codex)
        let claudePreset = AgentPreset(id: UUID(), name: "Claude · Personal", kind: .claude)
        let defaultGroup = SessionGroup(id: UUID(), name: "Default", isDefault: true)
        let reviewGroup = SessionGroup(id: UUID(), name: "Review", isDefault: false)

        return InventorySnapshot(
            hostName: hostName,
            capturedAt: Date(),
            projects: [
                ProjectSummary(
                    id: chauffeurProject,
                    name: "Chauffeur",
                    folders: [
                        FolderSummary(
                            id: chauffeurFolder,
                            name: "Chauffeur",
                            path: "~/Chauffeur",
                            isGitRepository: true,
                            checkouts: [
                                CheckoutSummary(id: mainCheckout, kind: .main, branch: "main", path: "~/Chauffeur"),
                                CheckoutSummary(id: mobileCheckout, kind: .worktree, branch: "feature/mobile", path: "~/Chauffeur/feature-mobile")
                            ]
                        )
                    ]
                ),
                ProjectSummary(
                    id: notesProject,
                    name: "Notes",
                    folders: [
                        FolderSummary(
                            id: notesFolder,
                            name: "notes",
                            path: "~/Documents/notes",
                            isGitRepository: false,
                            checkouts: [
                                CheckoutSummary(id: notesCheckout, kind: .main, branch: "folder", path: "~/Documents/notes")
                            ]
                        )
                    ]
                )
            ],
            sessions: [
                SessionSummary(
                    id: UUID(), title: "Mobile remote", kind: .codex, state: .waitingForInput, needsAttention: true,
                    projectID: chauffeurProject, folderID: chauffeurFolder, checkoutID: mobileCheckout,
                    branch: "feature/mobile", isOpenOnMac: true
                ),
                SessionSummary(
                    id: UUID(), title: "Review protocol", kind: .claude, state: .running, needsAttention: false,
                    projectID: chauffeurProject, folderID: chauffeurFolder, checkoutID: mobileCheckout,
                    branch: "feature/mobile", isOpenOnMac: false
                ),
                SessionSummary(
                    id: UUID(), title: "Shell", kind: .shell, state: .running, needsAttention: false,
                    projectID: chauffeurProject, folderID: chauffeurFolder, checkoutID: mainCheckout,
                    branch: "main", isOpenOnMac: false
                )
            ],
            presets: [codexPreset, claudePreset],
            groups: [defaultGroup, reviewGroup]
        )
    }
}
