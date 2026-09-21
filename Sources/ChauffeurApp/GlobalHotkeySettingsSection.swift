import AppKit
import SwiftUI
import ChauffeurCore

struct GlobalHotkeySettingsSection: View {
    @State private var configuration = GlobalMenuHotkey.load(from: .standard)
    @State private var monitor: Any?
    @State private var recording = false
    @State private var deadline = Date.distantPast
    @State private var message: String?

    var body: some View {
        Section("Global Hotkey") {
            Toggle("Open the menu bar menu", isOn: Binding(get: { configuration.enabled }, set: {
                configuration.enabled = $0; stopRecording(); save()
            }))
            HStack {
                Text("Shortcut")
                Spacer()
                Button(recording ? "Press a shortcut…" : configuration.displayName) { startRecording() }
                    .disabled(!configuration.enabled)
                Button("Reset") { stopRecording(); configuration = GlobalMenuHotkey(); save() }
            }
            Text(recording ? "Include Control, Option, or Command. Press Escape to cancel." : "Use this shortcut from any app, then use the arrow keys to choose Open Project…")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear { stopRecording() }
        .task {
            while !Task.isCancelled {
                if recording && Date() >= deadline { stopRecording() }
                if !recording {
                    UserDefaults.standard.synchronize()
                    if let data = UserDefaults.standard.data(forKey: GlobalMenuHotkey.statusKey),
                       let status = try? JSONDecoder().decode(GlobalMenuHotkeyStatus.self, from: data),
                       status.configuration == configuration { message = status.error }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    private func notifyHelper() {
        UserDefaults.standard.synchronize()
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(GlobalMenuHotkey.changedNotification), object: Bundle.main.bundleIdentifier, userInfo: nil, deliverImmediately: true)
    }
    private func save() {
        do { try configuration.save(to: .standard); message = nil; notifyHelper() }
        catch { message = error.localizedDescription }
    }
    private func startRecording() {
        stopRecording()
        recording = true; message = nil
        deadline = Date().addingTimeInterval(30)
        UserDefaults.standard.set(deadline.timeIntervalSince1970, forKey: GlobalMenuHotkey.recordingUntilKey)
        notifyHelper()
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window else { return event }
            if event.keyCode == 53 { stopRecording(); return nil }
            guard !event.isARepeat else { return nil }
            let flags = event.modifierFlags
            let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "Forward Delete", 123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
            let name = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
            let next = GlobalMenuHotkey(keyCode: UInt32(event.keyCode), key: name, control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift), command: flags.contains(.command))
            guard next.isValid else { message = "Include Control, Option, or Command in the shortcut."; return nil }
            configuration = next
            stopRecording(); save()
            return nil
        }
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; recording = false
        UserDefaults.standard.removeObject(forKey: GlobalMenuHotkey.recordingUntilKey)
        notifyHelper()
    }
}
