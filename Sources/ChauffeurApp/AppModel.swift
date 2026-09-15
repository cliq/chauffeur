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
    init() {}
}

@MainActor final class AppModel: ObservableObject {
    @Published var snapshot = AppSnapshot()
    @Published var online = false
    @Published var serviceMessage = "Connecting to background service…"
    @Published private(set) var serviceRegistrationError: String?
    @Published private(set) var isRestartingService = false
    @Published private(set) var isExportingDiagnostics = false
    private(set) var snapshotReceivedAt: Date?
    private var serviceDiagnosticError: NSError?
    private(set) var initialServiceStatus: Int?
    @Published var error: String?
    @Published var stopAllPresented = false
    @Published var openProjects = Set<UUID>()
    var isTerminating = false
    let socketPath: String
    private var observation: Task<Void, Never>?
    private var connection: SocketConnection?
    private var pendingWindows: [UUID: WindowState] = [:]
    private var windowVersions: [UUID: String] = [:]
    private var windowConflicts = Set<UUID>()
    private var windowWriter: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    private let service = SMAppService.agent(plistName: "dev.chauffeur.runtime.plist")

    init() {
        socketPath = ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] ?? Paths.applicationSupport.appendingPathComponent("runtime/runtime.sock").path
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.reconnect() }
        }
    }
    var projects: [Project] { snapshot.store.projects.map(\.value).sorted { $0.lastOpenedAt > $1.lastOpenedAt } }
    var presetSets: [PresetSet] { snapshot.store.presetSets.map(\.value) }
    var presets: [AgentPreset] { snapshot.store.presets.map(\.value) }
    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    func sessions(in projectID: UUID) -> [Session] { snapshot.sessions.filter { $0.projectID == projectID } }
    func setName(_ id: UUID) -> String { presetSets.first { $0.id == id }?.name ?? "Unresolved preset set" }
    func session(_ id: UUID?) -> Session? { snapshot.sessions.first { $0.id == id } }

    func start() {
        guard observation == nil else { return }
        #if DEBUG
        NativeProbe.start(model: self)
        #endif
        if ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] == nil { registerService() }
        #if DEBUG
        ServiceProbe.start(model: self)
        #endif
        observation = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
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
                        snapshot = try await Task.detached { try result.decode(AppSnapshot.self) }.value
                        snapshotReceivedAt = Date()
                        online = true; serviceMessage = "Background service running · \(snapshot.sessions.filter { $0.state.isLive }.count) live sessions"
                    }
                } catch {
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
        Task { _ = try? await call("reconcile") }
    }
    func registerService() {
        guard ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] == nil else { reconnect(); return }
        guard !isRestartingService else { return }
        if initialServiceStatus == nil { initialServiceStatus = service.status.rawValue }
        do {
            // An embedded agent without a background-task record may report
            // notFound before its first registration. Let register validate it.
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            serviceRegistrationError = nil; serviceDiagnosticError = nil
            if service.status == .requiresApproval { serviceMessage = "Allow Chauffeur in System Settings → Login Items & Extensions" }
            else if service.status == .enabled && UserDefaults.standard.string(forKey: "registeredRuntimeBuild") != runtimeBuildFingerprint {
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
    func restartService() {
        Task {
            do { try await restartRegisteredService() }
            catch { self.error = error.localizedDescription }
        }
    }
    private var runtimeBuildFingerprint: String? {
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/dev.chauffeur.runtime.plist")
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ChauffeurRuntime")
        guard let configuration = try? Data(contentsOf: plist), let executable = try? Data(contentsOf: helper, options: .mappedIfSafe) else { return nil }
        return JSONCoding.digest(configuration) + ":" + JSONCoding.digest(executable)
    }
    func restartRegisteredService() async throws {
        guard ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] == nil else { reconnect(); return }
        guard !isRestartingService else { return }
        isRestartingService = true; defer { isRestartingService = false }
        connection?.close(); online = false
        do {
            if service.status == .enabled { try await service.unregister() }
            try service.register(); serviceRegistrationError = nil; serviceDiagnosticError = nil; reconnect()
            if service.status == .enabled, let fingerprint = runtimeBuildFingerprint { UserDefaults.standard.set(fingerprint, forKey: "registeredRuntimeBuild") }
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
    func refresh() async throws {
        let result = try await call("snapshot")
        snapshot = try await Task.detached { try result.decode(AppSnapshot.self) }.value
        snapshotReceivedAt = Date()
        online = true
    }
    private var diagnosticApp: DiagnosticApp {
        DiagnosticApp(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, service: serviceStatus, error: serviceDiagnosticError)
    }
    func cachedDiagnostics() -> DiagnosticsReport {
        var report = DiagnosticsReport(sessions: snapshot.sessions, health: snapshot.health, errors: snapshot.store.errors + snapshot.errors,
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
            while let id = pendingWindows.keys.first, let value = pendingWindows.removeValue(forKey: id) {
                do {
                    let response = try await call("saveWindow", .object(["record": try .from(value), "version": windowVersions[id].map(JSONValue.string) ?? .null]))
                    let stored = try response.decode(Stored<WindowState>.self)
                    windowVersions[id] = stored.version
                    snapshot.store.windows.removeAll { $0.value.id == id }; snapshot.store.windows.append(stored)
                } catch {
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
    func stopAllAndQuit() {
        let targets = snapshot.sessions.filter { $0.state.isLive }.map(\.id)
        perform {
            for id in targets { _ = try await self.call("stop", .object(["sessionID": .string(id.uuidString), "force": .bool(false)])) }
            try await Task.sleep(for: .seconds(1)); try await self.refresh()
            let remaining = self.snapshot.sessions.filter { targets.contains($0.id) && $0.state.isLive }
            guard remaining.isEmpty else { throw ChauffeurError("sessions_still_running", "Some sessions are still stopping. Use Force stop in their details, then quit") }
            self.quit()
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
    static func directory(title: String = "Choose an existing folder") -> String? {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    static func executable() -> String? {
        let panel = NSOpenPanel(); panel.title = "Choose CLI executable"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
