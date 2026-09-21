import AppKit
import Carbon.HIToolbox
import ChauffeurCore

/// Registers with the OS, without an event tap or Accessibility permission.
@MainActor final class GlobalMenuHotkeyController {
    private var registration: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var applied: GlobalMenuHotkey?
    private var suspended = false
    private var preferences: UserDefaults?
    var openMenu: (() -> Void)?

    func update(preferences: UserDefaults) {
        self.preferences = preferences
        preferences.synchronize()
        let configuration = GlobalMenuHotkey.load(from: preferences)
        let recording = preferences.double(forKey: GlobalMenuHotkey.recordingUntilKey) > Date().timeIntervalSince1970
        guard applied != configuration || suspended != recording else { return }
        unregister()
        applied = configuration; suspended = recording
        guard configuration.enabled, !recording else { publish(configuration, error: nil); return }

        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identity = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
                      identity.signature == 0x43484652, identity.id == 1 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalMenuHotkeyController>.fromOpaque(context).takeUnretainedValue().pressed()
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { publish(configuration, error: "Could not enable the global hotkey (\(status))."); return }
        }
        var modifiers: UInt32 = 0
        if configuration.control { modifiers |= UInt32(controlKey) }
        if configuration.option { modifiers |= UInt32(optionKey) }
        if configuration.shift { modifiers |= UInt32(shiftKey) }
        if configuration.command { modifiers |= UInt32(cmdKey) }
        let identity = EventHotKeyID(signature: 0x43484652, id: 1)
        let status = RegisterEventHotKey(configuration.keyCode, modifiers, identity, GetApplicationEventTarget(), 0, &registration)
        publish(configuration, error: status == noErr ? nil : "Could not register \(configuration.displayName). It may be used by macOS or another app. Choose another shortcut (\(status)).")
    }

    private func pressed() {
        // Suppress the current binding immediately while the settings recorder
        // asks the helper to unregister it, even before the next refresh.
        preferences?.synchronize()
        guard (preferences?.double(forKey: GlobalMenuHotkey.recordingUntilKey) ?? 0) <= Date().timeIntervalSince1970 else { return }
        openMenu?()
    }
    private func publish(_ configuration: GlobalMenuHotkey, error: String?) {
        guard let data = try? JSONEncoder().encode(GlobalMenuHotkeyStatus(configuration: configuration, error: error)) else { return }
        preferences?.set(data, forKey: GlobalMenuHotkey.statusKey)
        preferences?.synchronize()
    }
    private func unregister() {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
    }
    func disconnect() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil; applied = nil
    }
}
