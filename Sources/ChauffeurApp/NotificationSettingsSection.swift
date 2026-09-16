import SwiftUI
import AppKit
import ChauffeurCore

struct NotificationSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var saving = false
    @State private var sendingTest = false
    @State private var testFeedback: String?
    private var status: NotificationStatus { model.snapshot.notifications ?? NotificationStatus() }
    private var testSession: Session? {
        model.snapshot.sessions.filter { session in model.snapshot.store.projects.contains { $0.value.id == session.projectID && !$0.value.archived } }
            .sorted { $0.updatedAt > $1.updatedAt }.first
    }
    var body: some View {
        Section("Notifications") {
            Toggle("Show session notifications", isOn: Binding(get: { status.enabled }, set: { setEnabled($0) }))
                .disabled(!model.online || saving || status.authorization == .unavailable)
            Text("Notifications show project and session names for input requests, completed turns, failures, and new messages or results. Click one to open its session, even after quitting Chauffeur.")
                .font(.caption).foregroundStyle(.secondary)
            if status.authorization == .unavailable {
                Text("Notifications require Chauffeur's installed app and default background service.").font(.caption)
            } else if status.enabled {
                if status.authorization == .denied {
                    Text("macOS has disabled notifications. Allow Chauffeur Notifications in System Settings → Notifications.").font(.caption)
                    Button("System Settings…") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
                } else if !status.helperConnected {
                    Text("Connecting to notifications…").font(.caption)
                } else if status.authorization == .notDetermined || status.authorization == .unknown {
                    Text("Allow notifications in the macOS permission prompt.").font(.caption)
                } else {
                    Text("Notifications are enabled. macOS Focus and notification settings may silence alerts.").font(.caption).foregroundStyle(.secondary)
                    Button("Send Test Notification") { sendTest() }
                        .disabled(sendingTest || !model.online || testSession == nil)
                        .accessibilityIdentifier("notifications.test")
                    if let session = testSession {
                        Text("The test opens “\(session.title)” without changing its session status.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Start a session to test its notification link.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let testFeedback { Text(testFeedback).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func sendTest() {
        guard !sendingTest, let session = testSession else { return }
        sendingTest = true; testFeedback = nil
        Task {
            defer { sendingTest = false }
            do {
                _ = try await model.call("testNotification", .object(["sessionID": .string(session.id.uuidString)]))
                testFeedback = "Test notification queued."
            } catch { model.error = error.localizedDescription }
        }
    }
    private func setEnabled(_ enabled: Bool) {
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await model.call("setNotifications", .object(["enabled": .bool(enabled)]))
                try await model.refresh()
            } catch { model.error = error.localizedDescription }
        }
    }
}
