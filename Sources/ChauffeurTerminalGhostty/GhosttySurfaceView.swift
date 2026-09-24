// GhosttySurfaceView
//
// An AppKit view around one host-managed `ghostty_surface_t`. Ghostty renders into the view's
// layer from its own renderer thread; the view forwards input, sizes, focus, visibility and
// appearance, and reports what the surface generates to its host (the adapter).
//
// The keyboard, IME and mouse handling follows Ghostty's macOS app
// (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift, MIT) and libghostty-spm's AppKit
// port of it (MIT, Copyright (c) Lakr233).

#if os(macOS)
import AppKit
import GhosttyKit

@MainActor
protocol GhosttySurfaceHost: AnyObject {
    /// Bytes for the remote process. The host applies its input gate.
    func surfaceDidGenerateInput(_ data: Data)
    func surfaceDidResizeGrid(columns: Int, rows: Int)
    func surfaceDidReceive(_ event: GhosttySurfaceEvent)
    /// Text from the app's Paste command or a file drop, to send as a paste.
    func surfaceWantsToPaste(_ text: String)
}

@MainActor
final class GhosttySurfaceView: NSView {
    weak var host: GhosttySurfaceHost?
    private(set) var configuration: GhosttyConfiguration
    private(set) var runtime: GhosttyRuntime?
    private(set) var surface: ghostty_surface_t?
    let output = GhosttyOutput()
    private let callbacks = GhosttySurfaceCallbacks()
    /// A configuration applied to the live surface after it was created from `runtime`'s,
    /// kept alive while the surface uses it.
    private var appliedConfig: GhosttyLoadedConfig?

    /// Keyboard focus requested while the view was not in a window yet.
    var focusesWhenAttached = false
    var acceptsFileDrops = false {
        didSet {
            if acceptsFileDrops { registerForDraggedTypes([.fileURL]) } else { unregisterDraggedTypes() }
        }
    }

    // Keyboard and IME state, see GhosttySurfaceView+Keyboard.swift.
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?
    var lastPerformKeyEvent: TimeInterval?
    // Mouse state, see GhosttySurfaceView+Mouse.swift.
    var cursor: NSCursor = .iBeam
    // Accessibility cache, see GhosttySurfaceView+Accessibility.swift.
    var accessibilityCache: (text: String, time: Date)?

    init(configuration: GhosttyConfiguration) {
        self.configuration = configuration
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        callbacks.view = self
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        tearDownSurface()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Surface lifecycle

    /// Creates the surface once the view is in a window with a real size, so Ghostty's first grid
    /// (and the size the remote process first sees) matches the view.
    func createSurfaceIfReady() {
        guard surface == nil, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        if runtime == nil { runtime = GhosttyRuntime.acquire(configuration) }
        guard let runtime else { return }

        let userdata = Unmanaged.passUnretained(callbacks).toOpaque()
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = userdata
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = userdata
        config.receive_buffer = ghosttyReceiveBuffer
        config.receive_resize = ghosttyReceiveResize
        config.scale_factor = Double(window?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        guard let surface = ghostty_surface_new(runtime.app, &config) else { return }
        self.surface = surface
        callbacks.setSurface(surface)
        synchronizeSize()
        updateDisplayID()
        applyConfiguration()
        ghostty_surface_set_color_scheme(surface, GhosttyRuntime.colorScheme(for: effectiveAppearance))
        updateFocus()
        updateOcclusion()
        output.attach(surface)
    }

    /// Frees the surface. Output waiting on the queue for it is skipped; output enqueued later
    /// waits for the next surface.
    func tearDownSurface() {
        guard let surface else { return }
        output.detach(ticking: runtime)
        callbacks.setSurface(nil)
        self.surface = nil
        // Ghostty may still be delivering a callback for this surface on another thread; the
        // callbacks object (held by `self`) outlives the free.
        ghostty_surface_free(surface)
        appliedConfig = nil
        accessibilityCache = nil
    }

    /// Switches to another configuration. A live surface is updated in place, keeping its screen
    /// and scrollback; without one, the next surface is created from the new configuration.
    func reconfigure(_ configuration: GhosttyConfiguration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        if surface != nil { applyConfiguration(); return }
        runtime?.release()
        runtime = nil
        createSurfaceIfReady()
    }

    /// Gives the live surface the configuration for the view's current appearance, unless it
    /// already has it. The shared runtime's config is reused when it matches.
    private func applyConfiguration() {
        guard let surface else { return }
        let dark = GhosttyRuntime.isDark(effectiveAppearance)
        let current = appliedConfig ?? runtime?.config
        guard current?.configuration != configuration || current?.dark != dark else { return }
        guard let config = GhosttyLoadedConfig(configuration, dark: dark) else { return }
        ghostty_surface_update_config(surface, config.raw)
        appliedConfig = config
    }

    func releaseRuntime() {
        tearDownSurface()
        runtime?.release()
        runtime = nil
    }

    // MARK: Output and generated input

    func handleGeneratedInput(_ data: Data) {
        host?.surfaceDidGenerateInput(data)
    }

    func handleGridResize(columns: Int, rows: Int) {
        host?.surfaceDidResizeGrid(columns: columns, rows: rows)
    }

    func handle(_ event: GhosttySurfaceEvent) {
        switch event {
        case .mouseShape(let raw):
            cursor = Self.cursor(for: ghostty_action_mouse_shape_e(rawValue: raw))
            window?.invalidateCursorRects(for: self)
        case .reloadConfig:
            guard let surface, let config = appliedConfig ?? runtime?.config else { return }
            ghostty_surface_update_config(surface, config.raw)
        default:
            host?.surfaceDidReceive(event)
        }
    }

    // MARK: Text

    func readText(includingScrollback: Bool) -> String? {
        guard let surface else { return nil }
        let tag = includingScrollback ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return Self.string(from: text)
    }

    func selectionText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return Self.string(from: text)
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    private static func string(from text: ghostty_text_s) -> String {
        guard let pointer = text.text, text.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)), as: UTF8.self)
    }

    // MARK: Window, size and appearance

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            updateOcclusion()
            updateFocus()
            return
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.didResignKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(windowScreenChanged), name: NSWindow.didChangeScreenNotification, object: window)
        if surface == nil { createSurfaceIfReady() } else { synchronizeSize() }
        updateDisplayID()
        updateOcclusion()
        updateFocus()
        if focusesWhenAttached {
            focusesWhenAttached = false
            // SwiftUI is still installing the view; take focus once it settles.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if surface == nil { createSurfaceIfReady() } else { synchronizeSize() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        runtime?.setColorScheme(for: effectiveAppearance)
        applyConfiguration()
        // Still reported so programs that asked for color-scheme updates (mode 2031) hear it.
        if let surface { ghostty_surface_set_color_scheme(surface, GhosttyRuntime.colorScheme(for: effectiveAppearance)) }
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        updateFocus()
        updateOcclusion()
    }

    @objc private func windowScreenChanged(_ notification: Notification) {
        // Let the window's new backing scale settle first.
        DispatchQueue.main.async { [weak self] in
            self?.updateDisplayID()
            self?.synchronizeSize()
        }
    }

    func synchronizeSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        let backing = convertToBacking(bounds.size)
        ghostty_surface_set_content_scale(surface, backing.width / bounds.width, backing.height / bounds.height)
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    private func updateDisplayID() {
        guard let surface, let number = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        ghostty_surface_set_display_id(surface, number.uint32Value)
    }

    /// Hidden surfaces keep parsing output but stop rendering; the window's occlusion
    /// notification brings them back.
    private func updateOcclusion() {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, window?.occlusionState.contains(.visible) ?? false)
    }

    func updateFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, window?.isKeyWindow == true && window?.firstResponder === self)
    }

    // MARK: Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let surface { ghostty_surface_set_focus(surface, window?.isKeyWindow == true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, let surface { ghostty_surface_set_focus(surface, false) }
        return resigned
    }

    /// Focuses the view now, or as soon as it is in a window.
    func focus() {
        guard let window else { focusesWhenAttached = true; return }
        window.makeFirstResponder(self)
    }
}
#endif
