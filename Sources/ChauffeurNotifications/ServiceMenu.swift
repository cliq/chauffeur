import AppKit
import ChauffeurCore

/// Owned by the accessory helper so quitting the main UI does not hide it.
@MainActor final class ServiceMenu: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var entries: [ActiveProject] = []
    private var tracking = false
    private var parentAppURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func update(_ entries: [ActiveProject]) {
        self.entries = entries
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            // Share the app's approved cap vector instead of duplicating its geometry.
            let image = Bundle(url: parentAppURL)?.image(forResource: "ChauffeurHat")?.copy() as? NSImage
            image?.size = NSSize(width: 20, height: 20 * 166.769 / 201.906)
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = "\(AppBuild.current.displayName) — Service running"
            item.button?.setAccessibilityLabel(AppBuild.current.displayName)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        if !tracking { rebuild() }
    }

    func disconnect() {
        statusItem?.menu?.cancelTracking()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        entries = []
    }

    func menuWillOpen(_ menu: NSMenu) { rebuild(); tracking = true }
    func menuDidClose(_ menu: NSMenu) { tracking = false }

    private func rebuild() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        let heading = menu.addItem(withTitle: "\(AppBuild.current.displayName) · Service running", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(.separator())
        if entries.isEmpty {
            menu.addItem(withTitle: "No active sessions", action: nil, keyEquivalent: "").isEnabled = false
        }
        for entry in entries {
            let count = entry.sessionCount
            let item = menu.addItem(withTitle: "\(entry.name) — \(count) active \(count == 1 ? "session" : "sessions")", action: #selector(openProject(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.route.url
        }
        menu.addItem(.separator())
        let chooser = menu.addItem(withTitle: "Open Project…", action: #selector(openProjectChooser), keyEquivalent: "")
        chooser.target = self
        let open = menu.addItem(withTitle: "Open \(AppBuild.current.displayName)…", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        let quit = menu.addItem(withTitle: "Quit Chauffeur...", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.toolTip = "Quit the app and background service."
    }

    @objc private func openProject(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        Task { await open(url: url) }
    }

    @objc private func quitApp() {
        // Registration belongs to the containing app, including when its UI is closed.
        Task { await open(url: QuitServiceRoute.url) }
    }

    @objc private func openProjectChooser() { Task { await open(url: WelcomeRoute.url) } }

    @objc private func openApp() { Task { await open(url: nil) } }

    private func open(url: URL?) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            if let url {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: parentAppURL, configuration: configuration)
            } else {
                _ = try await NSWorkspace.shared.openApplication(at: parentAppURL, configuration: configuration)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
