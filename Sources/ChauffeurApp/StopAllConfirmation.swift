import AppKit
import SwiftUI

/// App-wide confirmations have one native owner, even with several project
/// windows (or none). Capture the named targets before asking for confirmation.
@MainActor enum StopAllConfirmation {
    struct Target: Identifiable {
        let id: UUID
        let label: String
    }

    static func show(targets: [Target], completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Stop all sessions and quit?"
        alert.informativeText = targets.isEmpty ? "No sessions are running. Chauffeur will quit." : "These executions will receive a graceful stop request:"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop All and Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if !targets.isEmpty {
            let list = NSHostingView(rootView: List(targets) { Text($0.label).textSelection(.enabled) }
                .background(PersistentScrollbars()).scrollIndicators(.visible))
            list.frame = NSRect(x: 0, y: 0, width: 460, height: min(220, max(70, targets.count * 32)))
            alert.accessoryView = list
        }
        present(alert) { completion($0 == .alertFirstButtonReturn) }
    }

    static func failure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t stop all sessions"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// A nonblocking quit prompt. The standalone fallback must not enter runModal:
/// editor saves and terminal input still need the normal application run loop.
@MainActor final class QuitConfirmation: NSObject, NSWindowDelegate {
    enum Choice { case keepRunning, review, quit, forceQuit, cancel }
    private let alert = NSAlert()
    private var completion: ((Choice) -> Void)?
    private var choices: [Choice] = [.keepRunning, .cancel, .forceQuit]

    func showAppQuit(sessionCount: Int, completion: @escaping (Choice) -> Void) {
        self.completion = completion
        choices = [.keepRunning, .review, .cancel]
        alert.messageText = "Quit Chauffeur?"
        alert.informativeText = "\(sessionCount) active session\(sessionCount == 1 ? "" : "s") will keep running. The background service and menu bar icon will stay available so you can reopen your sessions."
        alert.addButton(withTitle: "Quit and Keep All Terminals Running")
        alert.addButton(withTitle: "Review Sessions")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        present()
    }
    func showServiceQuit(hasRunningSessions: Bool, completion: @escaping (Choice) -> Void) {
        self.completion = completion
        alert.messageText = "Quit Chauffeur and its background service?"
        alert.informativeText = hasRunningSessions
            ? "This will stop all running sessions, quit the app and background service, and remove the menu bar icon."
            : "The app and background service will quit, and the menu bar icon will close."
        choices = hasRunningSessions ? [.forceQuit, .cancel] : [.quit, .cancel]
        let quit = alert.addButton(withTitle: hasRunningSessions ? "Force Quit All Sessions..." : "Quit")
        quit.hasDestructiveAction = hasRunningSessions
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        present()
    }
    func showForceQuitConfirmation(completion: @escaping (Choice) -> Void) {
        self.completion = completion
        choices = [.cancel, .forceQuit]
        alert.messageText = "Force quit all sessions?"
        alert.informativeText = "This will immediately kill every Chauffeur session terminal across all projects, including running agents and shells. Unsaved work may be lost. The app and background service will then quit."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Force Quit All Sessions").hasDestructiveAction = true
        present()
    }
    private func present() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { [self] response in
                finish(choice(at: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue))
            }
        } else {
            alert.layout()
            alert.window.delegate = self
            for (index, button) in alert.buttons.enumerated() {
                button.tag = index; button.target = self; button.action = #selector(choose(_:))
            }
            alert.window.center()
            alert.window.makeKeyAndOrderFront(nil)
        }
    }
    @objc private func choose(_ button: NSButton) {
        alert.window.orderOut(nil)
        finish(choice(at: button.tag))
    }
    private func choice(at index: Int) -> Choice { choices.indices.contains(index) ? choices[index] : .cancel }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(.cancel); return true }
    private func finish(_ choice: Choice) {
        let callback = completion; completion = nil
        callback?(choice)
    }
}
