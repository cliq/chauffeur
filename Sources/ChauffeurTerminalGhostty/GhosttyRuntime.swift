#if os(macOS)
import AppKit
import GhosttyKit

/// One `ghostty_app_t` for a configuration, shared by the surfaces that use it and freed with the
/// last of them.
///
/// Ghostty's own threads only ask for the app to be ticked (`wakeup_cb`); every tick, action and
/// clipboard decision then runs on the main thread, as in Ghostty's macOS app. Nothing drives
/// frames from here: the renderer thread presents on its own display link.
@MainActor
final class GhosttyRuntime {
    private static var runtimes: [GhosttyConfiguration: GhosttyRuntime] = [:]

    /// The runtime for `configuration`, created on first use. Callers balance it with `release()`.
    static func acquire(_ configuration: GhosttyConfiguration) -> GhosttyRuntime? {
        let runtime = runtimes[configuration] ?? GhosttyRuntime(configuration)
        guard let runtime else { return nil }
        runtimes[configuration] = runtime
        runtime.users += 1
        return runtime
    }

    let app: ghostty_app_t
    let configuration: GhosttyConfiguration
    /// Config diagnostics Ghostty reported; empty for a config it accepted in full.
    var diagnostics: [String] { config.diagnostics }
    let config: GhosttyLoadedConfig
    private let handle: GhosttyRuntimeHandle
    private var users = 0

    private init?(_ configuration: GhosttyConfiguration) {
        Self.initializeLibrary()
        guard let config = GhosttyLoadedConfig(configuration, dark: Self.isDark(NSApp?.effectiveAppearance)) else { return nil }
        let handle = GhosttyRuntimeHandle()
        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(handle).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = ghosttyWakeup
        runtime.action_cb = ghosttyAction
        runtime.read_clipboard_cb = ghosttyReadClipboard
        runtime.confirm_read_clipboard_cb = ghosttyConfirmReadClipboard
        runtime.write_clipboard_cb = ghosttyWriteClipboard
        runtime.close_surface_cb = ghosttyCloseSurface
        guard let app = ghostty_app_new(&runtime, config.raw) else { return nil }
        self.app = app
        self.config = config
        self.configuration = configuration
        self.handle = handle
        handle.runtime = self
        setColorScheme(for: NSApp?.effectiveAppearance)
        ghostty_app_set_focus(app, NSApp?.isActive ?? true)
    }

    /// Called by each surface when it no longer needs the app. The app is freed on the next turn of
    /// the main loop so a callback already scheduled for it finds the handle cleared, not freed memory.
    func release() {
        users -= 1
        guard users <= 0, Self.runtimes[configuration] === self else { return }
        Self.runtimes[configuration] = nil
        handle.runtime = nil
        let app = app, config = config, handle = handle
        DispatchQueue.main.async {
            ghostty_app_free(app)
            withExtendedLifetime((config, handle)) {}
        }
    }

    func tick() {
        ghostty_app_tick(app)
    }


    func setColorScheme(for appearance: NSAppearance?) {
        ghostty_app_set_color_scheme(app, Self.colorScheme(for: appearance))
    }

    static func colorScheme(for appearance: NSAppearance?) -> ghostty_color_scheme_e {
        isDark(appearance) ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
    }

    static func isDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func setApplicationActive(_ active: Bool) {
        for runtime in runtimes.values { ghostty_app_set_focus(runtime.app, active) }
    }

    // MARK: Setup

    private static var initialized = false

    private static func initializeLibrary() {
        guard !initialized else { return }
        initialized = true
        // ghostty_init sets the process locale from the environment; the app formats numbers
        // assuming the C numeric locale, so restore it afterwards.
        let numeric = setlocale(LC_NUMERIC, nil).map { String(cString: $0) }
        ghostty_init(0, nil)
        if let numeric { setlocale(LC_NUMERIC, numeric) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { setApplicationActive(true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { setApplicationActive(false) }
        }
    }
}

/// A loaded, finalized Ghostty config and the generated files behind it, freed together.
final class GhosttyLoadedConfig: @unchecked Sendable {
    let raw: ghostty_config_t
    let diagnostics: [String]
    private let files: [URL]

    let configuration: GhosttyConfiguration
    let dark: Bool

    init?(_ configuration: GhosttyConfiguration, dark: Bool) {
        guard let file = try? Self.writeFile(configuration.rendered(dark: dark)), let raw = ghostty_config_new() else { return nil }
        ghostty_config_load_file(raw, file.path)
        ghostty_config_finalize(raw)
        self.raw = raw
        self.configuration = configuration
        self.dark = dark
        files = [file]
        diagnostics = (0..<ghostty_config_diagnostics_count(raw)).compactMap { index in
            ghostty_config_get_diagnostic(raw, index).message.map { String(cString: $0) }
        }
        #if DEBUG
        if !diagnostics.isEmpty { NSLog("Ghostty config diagnostics: %@", diagnostics.joined(separator: " | ")) }
        #endif
    }

    deinit {
        ghostty_config_free(raw)
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Generated files live in a per-process temporary directory: Ghostty has no API to load a
    /// config from memory.
    private static func writeFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Chauffeur", isDirectory: true)
            .appendingPathComponent("ghostty-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(UUID().uuidString).conf")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

/// The app's callback userdata. It outlives the runtime by one main-loop turn and coalesces
/// wakeups from Ghostty's threads into a single main-thread tick.
final class GhosttyRuntimeHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var tickScheduled = false
    /// Set and cleared on the main thread; read only there.
    nonisolated(unsafe) weak var runtime: GhosttyRuntime?

    func scheduleTick() {
        lock.lock()
        let schedule = !tickScheduled
        tickScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            lock.lock(); tickScheduled = false; lock.unlock()
            MainActor.assumeIsolated { runtime?.tick() }
        }
    }
}

// MARK: - C callbacks

private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    Unmanaged<GhosttyRuntimeHandle>.fromOpaque(userdata).takeUnretainedValue().scheduleTick()
}

/// Copies the action's payload before returning (its pointers are only valid during the call) and
/// delivers it to the surface on the main thread. Returns whether the action was handled; an
/// unhandled `open_url` would make Ghostty spawn `open` itself.
private func ghosttyAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    if target.tag == GHOSTTY_TARGET_APP {
        // Acknowledged but not answered: `ghostty_app_update_config` would push the app's config
        // onto every surface, replacing each terminal's own font and colors. Surfaces answer
        // their own reload requests.
        return action.tag == GHOSTTY_ACTION_RELOAD_CONFIG
    }
    guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
          let userdata = ghostty_surface_userdata(surface) else { return false }
    let callbacks = Unmanaged<GhosttySurfaceCallbacks>.fromOpaque(userdata).takeUnretainedValue()
    guard let event = GhosttySurfaceEvent(action) else { return false }
    callbacks.deliver(event)
    return true
}

private func ghosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?,
    _ mimes: UnsafePointer<UnsafePointer<CChar>?>?, _ mimeCount: Int, _ listAvailable: Bool
) -> ghostty_clipboard_read_result_e {
    // Pastes come from the app's own Paste command; programs may not read the clipboard.
    GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
}

private func ghosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e
) {
    guard let userdata, let state else { return }
    // An unanswered request would leave the program waiting forever.
    Unmanaged<GhosttySurfaceCallbacks>.fromOpaque(userdata).takeUnretainedValue().denyClipboardRequest(state)
}

/// A program set the clipboard (OSC 52). The text goes to the adapter's delegate, which decides
/// whether to write the pasteboard; Ghostty never writes it itself.
private func ghosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?, _ clipboard: ghostty_clipboard_e,
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int, _ confirm: Bool
) {
    guard let userdata, clipboard == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let contents, count > 0 else { return }
    let items = UnsafeBufferPointer(start: contents, count: count)
    guard let item = items.first(where: { $0.mime.map { String(cString: $0).hasPrefix("text/plain") } ?? false }) ?? items.first,
          let data = item.data else { return }
    let text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
    Unmanaged<GhosttySurfaceCallbacks>.fromOpaque(userdata).takeUnretainedValue().deliver(.clipboardWrite(text))
}

/// Host-managed surfaces have no child process to exit, so there is nothing to close.
private func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}
#endif
