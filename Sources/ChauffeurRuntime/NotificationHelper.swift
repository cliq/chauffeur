import AppKit
import ChauffeurCore
import ChauffeurRuntimeKit

enum NotificationHelper {
    /// A LaunchAgent cannot post standard notifications itself. Launch Services
    /// starts the embedded accessory app in the user's GUI session instead.
    @MainActor static func maintain(runtime: RuntimeCoordinator, executable: URL, root: URL) async {
        let helper = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Library/ChauffeurNotifications.app")
        let available = root.standardizedFileURL == Paths.applicationSupport.standardizedFileURL
            && FileManager.default.isExecutableFile(atPath: helper.appendingPathComponent("Contents/MacOS/ChauffeurNotifications").path)
        await runtime.configureNotifications(available: available)
        guard available else { return }
        var refreshed = false
        var reportedLaunchFailure = false
        while !Task.isCancelled {
            // The helper also owns the service menu, independently of notification opt-in.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppBuild.current.notificationIdentifier).filter { !$0.isTerminated }
            if !refreshed {
                // Refresh the helper after a service/app update. Otherwise an
                // old helper can route a click into the previous app bundle.
                for application in running { application.terminate() }
                refreshed = true
            }
            if running.isEmpty {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
                    reportedLaunchFailure = false
                } catch {
                    if !reportedLaunchFailure {
                        await runtime.record(ChauffeurError("notification_helper", "Could not start the notification helper. Reopen Chauffeur or reinstall its app bundle"))
                        reportedLaunchFailure = true
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
    }
}
