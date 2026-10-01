#if os(macOS)
import AppKit
import GhosttyKit

// Mouse, scrolling, the Edit menu, file drops and accessibility.
extension GhosttySurfaceView {
    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        leftClickStart = event.locationInWindow
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    /// The click reaches the program first. A plain click on a link then offers to open or copy
    /// it; a Cmd-click opens it.
    override func mouseUp(with event: NSEvent) {
        isReleasingLeftButton = true; openedLinkOnRelease = false
        sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        isReleasingLeftButton = false
        let start = leftClickStart
        leftClickStart = nil
        guard !openedLinkOnRelease, let start, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 else { return }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard modifiers.isEmpty || modifiers == .command, let link = linkUnderPointer(event) else { return }
        if modifiers == .command { host?.surfaceDidReceive(.openURL(link)) } else { showLinkMenu(link, event) }
    }

    /// The link Ghostty finds under the pointer: an OSC 8 hyperlink's target or a URL in the text.
    ///
    /// Ghostty only looks for links while Cmd is held, and not at all while the program reports
    /// the mouse (tmux always does) unless Shift releases it, so the view moves the pointer there
    /// with those modifiers and reads the hover Ghostty reports, then puts the real ones back.
    /// Leaving the surface first makes Ghostty look again at the same cell.
    private func linkUnderPointer(_ event: NSEvent) -> String? {
        guard let surface else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let x = point.x, y = bounds.height - point.y
        let mods = Self.ghosttyMods(event.modifierFlags)
        isProbingLink = true; probedLink = nil
        let probes = [GHOSTTY_MODS_SUPER.rawValue | GHOSTTY_MODS_SHIFT.rawValue, GHOSTTY_MODS_SUPER.rawValue]
        for probe in probes where probedLink == nil {
            ghostty_surface_mouse_pos(surface, -1, -1, mods)
            ghostty_surface_mouse_pos(surface, x, y, ghostty_input_mods_e(rawValue: probe))
        }
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
        isProbingLink = false
        ghostty_surface_mouse_pos(surface, x, y, mods)
        defer { probedLink = nil }
        return probedLink
    }

    private func showLinkMenu(_ link: String, _ event: NSEvent) {
        let menu = NSMenu()
        if let scheme = URL(string: link)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            let open = menu.addItem(withTitle: "Open Link", action: #selector(openLink(_:)), keyEquivalent: "")
            open.target = self; open.representedObject = link
        }
        let copy = menu.addItem(withTitle: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
        copy.target = self; copy.representedObject = link
        menu.addItem(.separator())
        menu.addItem(withTitle: link, action: nil, keyEquivalent: "").isEnabled = false
        popUpMenu(menu, at: event)
    }

    /// A plain pop-up rather than a context menu: AppKit adds AutoFill to a text input view's
    /// context menus.
    private func popUpMenu(_ menu: NSMenu, at event: NSEvent) {
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? String else { return }
        host?.surfaceDidReceive(.openURL(link))
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // With a selection the click opens Copy; otherwise it belongs to the program (tmux
        // shows its own menu).
        guard selectionText() == nil else {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
            popUpMenu(menu, at: event)
            return
        }
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event)
    }

    override func rightMouseUp(with event: NSEvent) { sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event)
    }

    override func otherMouseUp(with event: NSEvent) { sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event) }

    override func mouseMoved(with event: NSEvent) { sendPosition(event) }
    override func mouseDragged(with event: NSEvent) { sendPosition(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPosition(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPosition(event) }

    /// Ghostty clears link hover only for a negative position.
    override func mouseExited(with event: NSEvent) {
        guard NSEvent.pressedMouseButtons == 0, let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.ghosttyMods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas {
            mods |= 1
            // Trackpads report points; Ghostty's precise scrolling expects a finer scale.
            x *= 2; y *= 2
        }
        mods |= Int32(Self.momentum(event.momentumPhase).rawValue) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    private func sendButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) {
        guard let surface else { return }
        sendPosition(event)
        _ = ghostty_surface_mouse_button(surface, state, button, Self.ghosttyMods(event.modifierFlags))
    }

    private func sendPosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.ghosttyMods(event.modifierFlags))
    }

    private static func momentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        switch phase {
        case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: GHOSTTY_MOUSE_MOMENTUM_NONE
        }
    }

    static func cursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE: .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: .iBeamCursorForVerticalLayout
        default: .iBeam
        }
    }

    // MARK: Edit menu

    /// Copies the selection directly: Ghostty's clipboard callback is reserved for programs
    /// (OSC 52), which the adapter reports instead of writing.
    @objc func copy(_ sender: Any?) {
        guard let text = selectionText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Files paste as their shell-quoted paths, anything else as its text.
    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !files.isEmpty {
            host?.surfaceWantsToPaste(Self.shellQuoted(files))
        } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
            host?.surfaceWantsToPaste(text)
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }


    // MARK: File drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFileDrops && !droppedFiles(sender).isEmpty ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsFileDrops && !droppedFiles(sender).isEmpty
    }

    /// Drops travel the paste path, so the adapter's input gate and bracketed paste apply.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard acceptsFileDrops, !files.isEmpty else { return false }
        host?.surfaceWantsToPaste(Self.shellQuoted(files))
        window?.makeFirstResponder(self)
        return true
    }

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Single-quotes each path (spaces, apostrophes and shell metacharacters included) and adds
    /// a trailing space, as Terminal.app does.
    static func shellQuoted(_ files: [URL]) -> String {
        files.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") + " "
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { window?.makeFirstResponder(self) }
    }

    /// The visible rows (not the whole scrollback), cached briefly because assistive apps poll.
    override func accessibilityValue() -> Any? {
        if let cache = accessibilityCache, Date().timeIntervalSince(cache.time) < 0.5 { return cache.text }
        let text = readText(includingScrollback: false) ?? ""
        accessibilityCache = (text, Date())
        return text
    }

    override func accessibilitySelectedText() -> String? { selectionText() }

    /// The terminal is read-only to assistive apps; input comes from the keyboard.
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == NSSelectorFromString("setAccessibilityValue:") || selector == NSSelectorFromString("setAccessibilitySelectedText:") { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}
extension GhosttySurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): selectionText() != nil
        case #selector(paste(_:)): NSPasteboard.general.string(forType: .string) != nil
            || NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        case #selector(selectAll(_:)): surface != nil
        default: true
        }
    }
}
#endif
