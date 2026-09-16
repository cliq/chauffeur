#if DEBUG
import Foundation
import AppKit
import ServiceManagement
import ChauffeurCore

/// One-shot readout for real SMAppService registration using this app's bundled
/// LaunchAgent. Private test copies can supply their own job label/data directory
/// in that plist and CHAUFFEUR_SERVICE_PROBE_SOCKET without bypassing registration.
@MainActor enum ServiceProbe {
    private static var started = false
    static func start(model: AppModel) {
        guard !started, ProcessInfo.processInfo.environment["CHAUFFEUR_SOCKET"] == nil,
              let path = ProcessInfo.processInfo.environment["CHAUFFEUR_SERVICE_PROBE_DIR"] else { return }
        started = true
        Task {
            if ProcessInfo.processInfo.environment["CHAUFFEUR_SERVICE_PROBE_ACTION"] == "unregister" {
                do { try await SMAppService.agent(plistName: "dev.chauffeur.runtime.plist").unregister() }
                catch { model.error = error.localizedDescription }
            }
            if ProcessInfo.processInfo.environment["CHAUFFEUR_SERVICE_PROBE_RESTART"] == "1" {
                do { try await model.restartRegisteredService() }
                catch { model.error = error.localizedDescription }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while (!model.online || model.isRestartingService || model.snapshot.health["mcpEndpoint"].string == nil || !NSApp.windows.contains(where: \.isVisible)) && ContinuousClock.now < deadline && ProcessInfo.processInfo.environment["CHAUFFEUR_SERVICE_PROBE_ACTION"] != "unregister" { try? await Task.sleep(for: .milliseconds(100)) }
            let result: JSONValue = .object([
                "initialStatus": model.initialServiceStatus.map { .number(Double($0)) } ?? .null,
                "status": .string(model.serviceStatus), "online": .bool(model.online),
                "message": .string(model.serviceMessage), "registrationError": model.serviceRegistrationError.map(JSONValue.string) ?? .null,
                "health": model.snapshot.health,
                "visibleWindows": .number(Double(NSApp.windows.filter(\.isVisible).count)),
                "startupErrorCodes": .array(model.snapshot.errors.map { .string($0.code) }),
                "error": model.error.map(JSONValue.string) ?? .null
            ])
            do {
                let root = URL(fileURLWithPath: try Paths.directory(path))
                let output = root.appendingPathComponent("service-probe.json")
                try JSONCoding.encode(result).write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            } catch { }
            model.quit()
        }
    }
}
#endif
