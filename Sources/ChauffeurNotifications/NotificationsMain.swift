import AppKit
import UserNotifications
import ChauffeurCore

/// User Notifications must run in a user-level application, not our launch agent.
@main @MainActor struct NotificationsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = NotificationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class NotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var worker: Task<Void, Never>?
    private var menuWorker: Task<Void, Never>?
    private let serviceMenu = ServiceMenu()
    private struct MenuSnapshot: Decodable {
        let store: StoreSnapshot
        let sessions: [Session]
    }
    private var requestingAuthorization = false
    private let socket = Paths.applicationSupport.appendingPathComponent("runtime/runtime.sock").path

    func applicationWillFinishLaunching(_ notification: Notification) { center.delegate = self }
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuWorker = Task {
            while !Task.isCancelled {
                do {
                    let snapshot = try await call("snapshot").decode(MenuSnapshot.self)
                    serviceMenu.update(ActiveProject.entries(projects: snapshot.store.projects.map(\.value),
                        sessions: snapshot.sessions, windows: snapshot.store.windows.map(\.value)))
                } catch { serviceMenu.disconnect() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        worker = Task {
            while !Task.isCancelled {
                do { try await poll() }
                catch { /* Runtime restarts and temporary OS delivery errors are retried. */ }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        worker?.cancel()
        menuWorker?.cancel()
        serviceMenu.disconnect()
    }
    private func call(_ method: String, _ params: JSONValue = .object([:])) async throws -> JSONValue {
        try await RuntimeClient.call(IPCRequest(method, params: params), socketPath: socket)
    }
    private func poll() async throws {
        let settings = await center.notificationSettings()
        let authorization: NotificationAuthorization
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized: authorization = .authorized
        case .provisional: authorization = .provisional
        @unknown default: authorization = .unavailable
        }
        let result = try await call("notificationWork", .object(["authorization": .string(authorization.rawValue)]))
        let work = try result.decode(NotificationWork.self)
        guard work.enabled else {
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            return
        }
        if authorization == .notDetermined && !requestingAuthorization {
            // Menu bar availability does not opt the user into notifications.
            requestingAuthorization = true
            _ = try await center.requestAuthorization(options: [.alert])
            return
        }
        guard authorization == .authorized || authorization == .provisional else { return }
        for delivery in work.deliveries {
            // Recheck opt-in before every delivery, including after an OS prompt.
            let status = try await call("notificationStatus").decode(NotificationStatus.self)
            guard status.enabled else { return }
            let content = UNMutableNotificationContent()
            content.title = delivery.project
            content.subtitle = delivery.session
            content.body = delivery.notice.reason.body
            content.threadIdentifier = delivery.notice.route.projectID.uuidString
            content.userInfo = ["route": delivery.notice.route.url.absoluteString]
            try await center.add(UNNotificationRequest(identifier: delivery.notice.identifier, content: content, trigger: nil))
            _ = try await call("acknowledgeNotification", .object(["noticeID": .string(delivery.notice.id.uuidString)]))
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let text = response.notification.request.content.userInfo["route"] as? String,
              let url = URL(string: text), let route = SessionRoute(url: url) else { completionHandler(); return }
        Task { @MainActor in
            defer { completionHandler() }
            // Open our containing app explicitly; another installed build must not
            // capture the URL through Launch Services' global scheme association.
            let parent = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try? await NSWorkspace.shared.open([route.url], withApplicationAt: parent, configuration: configuration)
        }
    }
}
