import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers
import ChauffeurCore

struct AppSnapshot: Decodable, Sendable {
    var store = StoreSnapshot()
    var sessions: [Session] = []
    var messages: [Message] = []
    var delegations: [Delegation] = []
    var health: JSONValue = .null
    var settings = RetentionSettings()
    var snapshotStorage = SnapshotStorageStatus(budgetBytes: RetentionSettings().snapshotBudgetBytes)
    var errors: [ChauffeurError] = []
    var repositoryInventories: [RepositoryInventory]?
    var notifications: NotificationStatus?
    init() {}
}

@MainActor final class AppModel: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet {
            preferences.set(appearance.rawValue, forKey: AppAppearance.preferenceKey)
            applyAppearance()
        }
    }
    private let preferences: UserDefaults
    private func applyAppearance() { NSApplication.shared.appearance = appearance.nativeAppearance }
    struct Navigation: Equatable { var id = UUID(); let route: SessionRoute }
    struct ProjectNavigation: Equatable { var id = UUID(); let match: ProjectFolderMatch }
    struct FolderSelection: Identifiable { let id = UUID(); let path: String; let matches: [ProjectFolderMatch] }
    struct ProjectCreation: Identifiable { let id = UUID(); var folderPath: String? = nil }
    @Published var projectCreation: ProjectCreation?
    @Published var pendingSessionRoute: Navigation?
    @Published var pendingProjectRoute: ProjectNavigation?
    @Published var folderSelection: FolderSelection?
    private var pendingWelcomeRoute = false
    private var pendingFolderRoute: FolderRoute?
    private(set) var skipAutomaticWindowRestore = false
    var hasPendingNavigation: Bool { pendingWelcomeRoute || pendingSessionRoute != nil || pendingProjectRoute != nil || pendingFolderRoute != nil || folderSelection != nil || projectCreation != nil }
    var openProjectWindow: ((UUID) -> Void)?
    var openWelcomeWindow: (() -> Void)?
    private var openedRouteID: UUID?
    func openSessionURL(_ url: URL) {
        if url == WelcomeRoute.url {
            skipAutomaticWindowRestore = true
            pendingSessionRoute = nil; pendingProjectRoute = nil; pendingFolderRoute = nil
            folderSelection = nil; projectCreation = nil
            pendingWelcomeRoute = true
            processPendingRoute()
            return
        }
        if let route = FolderRoute(url: url) {
            pendingWelcomeRoute = false
            skipAutomaticWindowRestore = true
            pendingSessionRoute = nil; pendingProjectRoute = nil; folderSelection = nil; projectCreation = nil
            pendingFolderRoute = route
            processPendingRoute()
            return
        }
        guard let route = SessionRoute(url: url) else { return }
        pendingWelcomeRoute = false
        skipAutomaticWindowRestore = true
        pendingFolderRoute = nil; pendingProjectRoute = nil; folderSelection = nil; projectCreation = nil
        pendingSessionRoute = Navigation(route: route)
        processPendingRoute()
    }
    func processPendingRoute() {
        if pendingWelcomeRoute, let openWelcomeWindow {
            pendingWelcomeRoute = false
            openWelcomeWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
        processFolderRoute()
        guard online, let navigation = pendingSessionRoute, let openProjectWindow else { return }
        guard project(navigation.route.projectID) != nil, session(navigation.route.sessionID)?.projectID == navigation.route.projectID else {
            error = "The notification's project or session is no longer available."
            pendingSessionRoute = nil; openWelcomeWindow?(); return
        }
        guard openedRouteID != navigation.id else { return }
        openedRouteID = navigation.id
        openProjectWindow(navigation.route.projectID)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func processFolderRoute() {
        guard online, let route = pendingFolderRoute, openProjectWindow != nil, openWelcomeWindow != nil else { return }
        pendingFolderRoute = nil
        do {
            let path = try Paths.directory(route.path)
            let matches = ProjectFolderResolver.matches(path: path, projects: projects, worktrees: snapshot.store.worktrees.map(\.value), inventories: snapshot.repositoryInventories ?? [])
            if matches.count == 1 { chooseProjectForFolder(matches[0]) }
            else if matches.isEmpty {
                projectCreation = ProjectCreation(folderPath: path)
                openWelcomeWindow?()
            } else {
                folderSelection = FolderSelection(path: path, matches: matches)
                openWelcomeWindow?()
            }
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            self.error = error.localizedDescription; openWelcomeWindow?()
        }
    }
    func chooseProjectForFolder(_ match: ProjectFolderMatch) {
        guard project(match.projectID) != nil else { folderSelection = nil; return }
        folderSelection = nil
        pendingProjectRoute = ProjectNavigation(match: match)
        openProjectWindow?(match.projectID)
        NSApp.activate(ignoringOtherApps: true)
    }
    @Published var snapshot = AppSnapshot()
    @Published var online = false
    @Published var serviceMessage = "Connecting to background service…"
    @Published private(set) var serviceRegistrationError: String?
    @Published private(set) var isRestartingService = false
    @Published private(set) var isStoppingService = false
    @Published private(set) var isServiceStopped = false
    var canStopService: Bool { !usesCustomSocket && !isRestartingService && !isStoppingService && !isServiceStopped && (online || service.status == .enabled || service.status == .requiresApproval) }
    @Published private(set) var isExportingDiagnostics = false
    private(set) var snapshotReceivedAt: Date?
    private var serviceDiagnosticError: NSError?
    private(set) var initialServiceStatus: Int?
    @Published var error: String?
    @Published private(set) var stopAllPresented = false
    @Published private(set) var isStoppingAll = false
    @Published var openProjects = Set<UUID>()
    var isTerminating = false
    let socketPath: String
    private var observation: Task<Void, Never>?
    private var connection: SocketConnection?
    private var connectionGeneration = 0
    private var pendingWindows: [UUID: WindowState] = [:]
    private var windowVersions: [UUID: String] = [:]
    private var windowConflicts = Set<UUID>()
    private var windowWriter: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    private let service = SMAppService.agent(plistName: "dev.chauffeur.runtime.plist")
    private var attemptedIdentityRepair = false
    private var usesCustomSocket: Bool { ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] != nil }
    private lazy var expectedRuntimeIdentity: RuntimeIdentity? = {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ChauffeurRuntime")
        let root = URL(fileURLWithPath: socketPath).deletingLastPathComponent().deletingLastPathComponent()
        return try? RuntimeIdentity(executable: executable, dataRoot: root)
    }()
    var runtimeIdentity: RuntimeIdentity? { try? snapshot.health["identity"].decode(RuntimeIdentity.self) }
    var runtimeConnectionVerified: Bool { online && !usesCustomSocket }

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        appearance = AppAppearance(rawValue: preferences.string(forKey: AppAppearance.preferenceKey) ?? "") ?? .system
        var configuredSocket = ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"]
        #if DEBUG
        // Exercise the real bundled SMAppService registration with a private
        // test job/store. CHAUFFEUR_SOCKET intentionally bypasses registration.
        configuredSocket = configuredSocket ?? ProcessInfo.processInfo.environment["CHAUFFEUR_SERVICE_PROBE_SOCKET"]
        #endif
        socketPath = configuredSocket ?? Paths.applicationSupport.appendingPathComponent("runtime/runtime.sock").path
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.reconnect() }
        }
        applyAppearance()
    }
    var projects: [Project] { snapshot.store.projects.map(\.value).sorted { $0.lastOpenedAt > $1.lastOpenedAt } }
    var presetSets: [PresetSet] { snapshot.store.presetSets.map(\.value) }
    var presets: [AgentPreset] { snapshot.store.presets.map(\.value) }
    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    func sessions(in projectID: UUID) -> [Session] { snapshot.sessions.filter { $0.projectID == projectID } }
    func setName(_ id: UUID) -> String { presetSets.first { $0.id == id }?.name ?? "Unresolved team" }
    func session(_ id: UUID?) -> Session? { snapshot.sessions.first { $0.id == id } }

    func start() {
        guard observation == nil else { return }
        #if DEBUG
        NativeProbe.start(model: self)
        LauncherProbe.start(model: self)
        QuickSessionProbe.start(model: self)
        #endif
        if ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] == nil { registerService() }
        #if DEBUG
        ServiceProbe.start(model: self)
        #endif
        observation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if isRestartingService || isStoppingService || isServiceStopped { try? await Task.sleep(for: .milliseconds(100)); continue }
                let generation = connectionGeneration
                do {
                    let socket = try SocketConnection(path: socketPath)
                    connection = socket
                    defer { socket.close() }
                    try await socket.sendAsync(IPCRequest("subscribe"))
                    while !Task.isCancelled {
                        let response = try await socket.receiveAsync(IPCResponse.self)
                        guard response.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "App and service versions differ. Restart the background service") }
                        if let failure = response.error { throw failure }
                        guard let result = response.result else { continue }
                        let received = try await Task.detached { try result.decode(AppSnapshot.self) }.value
                        guard generation == connectionGeneration, !isRestartingService, !isStoppingService, !isServiceStopped else { break }
                        if !usesCustomSocket {
                            guard let expected = expectedRuntimeIdentity else {
                                throw ChauffeurError("runtime_identity_unavailable", "Cannot verify the bundled runtime. Rebuild or reinstall Chauffeur")
                            }
                            guard (try? received.health["identity"].decode(RuntimeIdentity.self)) == expected else {
                                // Repair once per app launch. Never accept a snapshot from
                                // another installation, or repeatedly restart competing apps.
                                if !attemptedIdentityRepair {
                                    attemptedIdentityRepair = true
                                    restartService()
                                    break
                                }
                                throw ChauffeurError("runtime_mismatch", "The background service belongs to a different app build or location. Restart Service from Runtime settings")
                            }
                            if let fingerprint = runtimeBuildFingerprint { preferences.set(fingerprint, forKey: "registeredRuntimeBuild") }
                        }
                        snapshot = received
                        snapshotReceivedAt = Date()
                        online = true; serviceMessage = "\(usesCustomSocket ? "Custom" : AppBuild.current.rawValue) service running\(usesCustomSocket ? "" : " · verified") · \(snapshot.sessions.filter { $0.state.isLive }.count) live sessions"
                        processPendingRoute()
                    }
                } catch {
                    guard generation == connectionGeneration else { continue }
                    online = false
                    if ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] == nil && service.status == .requiresApproval {
                        serviceMessage = "Allow Chauffeur in System Settings → Login Items & Extensions"
                    } else if let serviceRegistrationError { serviceMessage = serviceRegistrationError }
                    else { serviceMessage = (error as? ChauffeurError)?.message ?? "Background service disconnected" }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
    func reconnect() {
        connection?.close()
    }
    func registerService(forceRestart: Bool = false) {
        guard ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] == nil else { reconnect(); return }
        guard !isRestartingService, !isStoppingService else { return }
        isServiceStopped = false
        if initialServiceStatus == nil { initialServiceStatus = service.status.rawValue }
        do {
            // An embedded agent without a background-task record may report
            // notFound before its first registration. Let register validate it.
            let needsRegistration = service.status == .notRegistered || service.status == .notFound
            if needsRegistration { try service.register() }
            serviceRegistrationError = nil; serviceDiagnosticError = nil
            if service.status == .requiresApproval { serviceMessage = "Allow Chauffeur in System Settings → Login Items & Extensions" }
            else if service.status == .enabled && !needsRegistration && (forceRestart || preferences.string(forKey: "registeredRuntimeBuild") != runtimeBuildFingerprint) {
                // SMAppService can retain a previous helper's launch constraint,
                // even after unregistering it. Refresh registration for new code.
                restartService()
            }
        } catch {
            serviceRegistrationError = "Background service could not register: \(error.localizedDescription)"
            serviceDiagnosticError = error as NSError
            serviceMessage = serviceRegistrationError!
        }
    }
    var serviceStatus: String {
        if ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] != nil { return "customConnection" }
        switch service.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
    func stopService() {
        guard canStopService else { return }
        isStoppingService = true
        Task {
            defer { isStoppingService = false }
            await finishPendingWindowWrites()
            connectionGeneration += 1
            connection?.close()
            online = false
            serviceMessage = "Stopping background service…"
            do {
                // Unregister instead of killing the process: launchd must not
                // immediately relaunch the service's KeepAlive job.
                try await service.unregister()
                isServiceStopped = true
                serviceRegistrationError = nil; serviceDiagnosticError = nil
                serviceMessage = "Background service stopped"
            } catch {
                serviceRegistrationError = "Background service could not stop: \(error.localizedDescription)"
                serviceDiagnosticError = error as NSError
                serviceMessage = serviceRegistrationError!
                self.error = serviceRegistrationError
            }
        }
    }
    func restartService() {
        guard beginServiceRestart() else { return }
        Task {
            do { try await completeServiceRestart() }
            catch { self.error = error.localizedDescription }
        }
    }
    private lazy var runtimeBuildFingerprint: String? = {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/dev.chauffeur.runtime.plist")
        guard let configuration = try? Data(contentsOf: plist) else { return nil }
        return expectedRuntimeIdentity?.registrationFingerprint(plist: configuration)
    }()
    func restartRegisteredService() async throws {
        guard beginServiceRestart() else { return }
        try await completeServiceRestart()
    }
    private func beginServiceRestart() -> Bool {
        guard ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] == nil else { reconnect(); return false }
        guard !isRestartingService, !isStoppingService else { return false }
        isServiceStopped = false
        // Set this synchronously, before startup can subscribe to the old helper.
        isRestartingService = true
        connectionGeneration += 1
        connection?.close(); online = false
        return true
    }
    private func completeServiceRestart() async throws {
        defer { isRestartingService = false }
        do {
            if service.status == .enabled { try await service.unregister() }
            try service.register(); serviceRegistrationError = nil; serviceDiagnosticError = nil; reconnect()
            // Record this registration only after a matching runtime connects.
            // The subscription reconnects when startup finishes. An immediate
            // snapshot request would report a spurious error during shell setup.
        } catch {
            serviceRegistrationError = "Background service could not restart: \(error.localizedDescription)"
            serviceDiagnosticError = error as NSError
            serviceMessage = serviceRegistrationError!
            throw error
        }
    }
    func openServiceSettings() { SMAppService.openSystemSettingsLoginItems() }
    func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await RuntimeClient.call(IPCRequest(method, params: params), socketPath: socketPath)
    }
    /// Whether a session's terminal is waiting at its own prompt. An
    /// unreachable service counts as active so closing still asks first.
    func terminalActivity(_ sessionID: UUID) async -> TerminalActivity {
        guard online, let result = try? await call("sessionActivity", .object(["sessionID": .string(sessionID.uuidString)])),
              let activity = try? result.decode(TerminalActivity.self) else { return TerminalActivity(idle: false, command: nil) }
        return activity
    }
    func refresh() async throws {
        let generation = connectionGeneration
        let result = try await call("snapshot")
        let received = try await Task.detached { try result.decode(AppSnapshot.self) }.value
        guard generation == connectionGeneration, !isRestartingService, !isStoppingService, !isServiceStopped else { return }
        snapshot = received
        snapshotReceivedAt = Date()
        online = true
        processPendingRoute()
    }
    private var diagnosticApp: DiagnosticApp {
        DiagnosticApp(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, service: serviceStatus, error: serviceDiagnosticError)
    }
    func cachedDiagnostics() -> DiagnosticsReport {
        var report = DiagnosticsReport(sessions: snapshot.sessions, health: snapshot.health, errors: snapshot.store.errors + (snapshot.repositoryInventories ?? []).compactMap(\.error) + snapshot.errors,
            observation: snapshotReceivedAt == nil ? .unavailable : .cached, observedAt: snapshotReceivedAt)
        report.app = diagnosticApp
        return report
    }
    func makeDiagnostics() async -> DiagnosticsReport {
        do {
            var report = try await call("diagnostics").decode(DiagnosticsReport.self)
            guard report.schemaVersion == 1 else { return cachedDiagnostics() }
            report.app = diagnosticApp
            return report
        } catch { return cachedDiagnostics() }
    }
    func exportDiagnostics() {
        guard !isExportingDiagnostics else { return }
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"; panel.nameFieldStringValue = "Chauffeur-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Includes session paths, versions, state, and error codes. Paths can identify your user account and projects."
        isExportingDiagnostics = true
        panel.begin { [weak self] response in
            guard let self else { return }
            guard response == .OK, let destination = panel.url else { self.isExportingDiagnostics = false; return }
            Task {
                defer { self.isExportingDiagnostics = false }
                let report = await self.makeDiagnostics()
                do { try await Task.detached { try report.write(to: destination) }.value }
                catch { self.error = error.localizedDescription }
            }
        }
    }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation(); try await refresh() }
            catch { self.error = error.localizedDescription; try? await refresh() }
        }
    }
    /// Returns the worktree record ID for a checkout, registering the Git
    /// worktree first when Chauffeur has no record yet. The main checkout has none.
    func worktreeID(for row: CheckoutRow, project: Project) async throws -> UUID? {
        if row.isMain { return nil }
        if let id = row.worktreeID { return id }
        let stored = try await call("registerWorktree", .object(["projectID": .string(project.id.uuidString), "folderID": .string(row.folderID.uuidString), "path": .string(row.path)])).decode(Stored<Worktree>.self)
        try await refresh()
        return stored.value.id
    }
    /// Starts a login shell in a checkout as a service-backed session.
    func launchShell(project: Project, folder: ProjectFolder, worktreeID: UUID?, branch: String) async throws -> Session {
        guard let group = project.groups.first(where: { $0.isDefault && !$0.archived }) ?? project.groups.first(where: { !$0.archived }) else {
            throw ChauffeurError("missing_group", "Add an active group to this project before opening a shell")
        }
        let title = "Shell · \(branch.isEmpty ? folder.name : branch)"
        let request = LaunchRequest.shell(projectID: project.id, groupID: group.id, folderID: folder.id, title: title, worktreeID: worktreeID)
        let session = try await call("launch", .from(request)).decode(Session.self)
        try await refresh()
        return session
    }
    func save<T: ChauffeurCore.Record>(_ method: String, _ value: T, version: String?) async throws {
        _ = try await call(method, .object(["record": try .from(value), "version": version.map(JSONValue.string) ?? .null]))
        try await refresh()
    }
    func projectVersion(_ id: UUID) -> String? { snapshot.store.projects.first { $0.value.id == id }?.version }
    func saveProject(_ value: Project, version: String?) async throws {
        try await save("saveProject", value, version: version)
    }
    func projectOpened(_ id: UUID) {
        openProjects.insert(id)
        guard var project = project(id) else { return }
        let version = projectVersion(id)
        project.lastOpenedAt = Date(); perform { try await self.saveProject(project, version: version) }
    }
    func saveWindow(_ state: WindowState) {
        guard !windowConflicts.contains(state.id) else { return }
        pendingWindows[state.id] = state
        guard windowWriter == nil else { return }
        windowWriter = Task {
            defer { windowWriter = nil }
            while let id = pendingWindows.keys.first {
                if !online || isRestartingService { try? await Task.sleep(for: .milliseconds(100)); continue }
                guard let value = pendingWindows.removeValue(forKey: id) else { continue }
                do {
                    let response = try await call("saveWindow", .object(["record": try .from(value), "version": windowVersions[id].map(JSONValue.string) ?? .null]))
                    let stored = try response.decode(Stored<WindowState>.self)
                    windowVersions[id] = stored.version
                    snapshot.store.windows.removeAll { $0.value.id == id }; snapshot.store.windows.append(stored)
                } catch {
                    if (error as? ChauffeurError)?.code == "service_unavailable" {
                        // No connection was opened, so the write was never sent.
                        // Keep the newest queued layout and retry after reconnect.
                        if pendingWindows[id] == nil { pendingWindows[id] = value }
                        online = false; connection?.close()
                        continue
                    }
                    pendingWindows.removeValue(forKey: id); windowConflicts.insert(id)
                    self.error = "\(error.localizedDescription)\nClose and reopen this project window to reload its saved layout."
                    try? await refresh()
                }
            }
        }
    }
    func beginWindowEditing(_ id: UUID) {
        windowVersions[id] = snapshot.store.windows.first { $0.value.id == id }?.version
        windowConflicts.remove(id)
    }
    func confirmStopAllAndQuit() {
        guard !stopAllPresented, !isStoppingAll else { return }
        let targets = snapshot.sessions.filter { $0.state.isLive }.map {
            StopAllConfirmation.Target(id: $0.id, label: "\(project($0.projectID)?.name ?? "Project unavailable") · \($0.title)")
        }
        stopAllPresented = true
        StopAllConfirmation.show(targets: targets) { [weak self] confirmed in
            guard let self else { return }
            self.stopAllPresented = false
            if confirmed { self.stopAllAndQuit(targets: targets.map(\.id)) }
        }
    }
    private func stopAllAndQuit(targets: [UUID]) {
        guard !isStoppingAll else { return }
        isStoppingAll = true
        Task {
            defer { isStoppingAll = false }
            do {
                for id in targets { _ = try await call("stop", .object(["sessionID": .string(id.uuidString), "force": .bool(false)])) }
                try await Task.sleep(for: .seconds(1)); try await refresh()
                let remaining = snapshot.sessions.filter { targets.contains($0.id) && $0.state.isLive }
                guard remaining.isEmpty else { throw ChauffeurError("sessions_still_running", "Some sessions are still stopping. Use Force Stop in their details, then quit") }
                quit()
            } catch { StopAllConfirmation.failure(error.localizedDescription) }
        }
    }
    func finishPendingWindowWrites() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while windowWriter != nil && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }
    func quit() {
        Task {
            await finishPendingWindowWrites()
            NSApplication.shared.terminate(nil)
        }
    }
}

@MainActor enum FilePanels {
    static func directory(title: String = "Choose an existing folder", startingAt directory: URL? = nil, showsHiddenFiles: Bool = false) -> String? {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseFiles = false; panel.canChooseDirectories = true
        if let directory { panel.directoryURL = directory }
        panel.showsHiddenFiles = showsHiddenFiles
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    static func executable() -> String? {
        let panel = NSOpenPanel(); panel.title = "Choose CLI executable"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
