import AppKit
import Combine
import ChauffeurCore

/// Asks the user before an agent ends its own session to remove the worktree it
/// works in, so the session and its checkout don't vanish unexplained. One owner
/// for the whole app, so several project windows show a request once. Requests
/// wait their turn; one whose session ended some other way is dismissed.
/// The prompt arrives unasked, so Return keeps the session, and it never enters
/// `runModal`: terminals still need the normal run loop.
@MainActor final class WorktreeRemovalPrompt: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var subscription: AnyCancellable?
    private var active: (request: WorktreeRemovalRequest, alert: NSAlert)?
    /// Requests already answered or dismissed, so a snapshot that still lists one doesn't ask again.
    private var handled = Set<UUID>()

    init(model: AppModel) {
        self.model = model
        super.init()
        subscription = model.$snapshot.sink { [weak self] snapshot in
            // Published values arrive before the property itself changes.
            let requests = snapshot.worktreeRemovalRequests ?? []
            Task { @MainActor [weak self] in self?.update(requests) }
        }
    }

    private func update(_ requests: [WorktreeRemovalRequest]) {
        let ids = Set(requests.map(\.id))
        handled.formIntersection(ids)
        if let active, !ids.contains(active.request.id) {
            // The session ended some other way: nothing is left to answer.
            self.active = nil
            let window = active.alert.window
            if let parent = window.sheetParent { parent.endSheet(window, returnCode: .abort) } else { window.orderOut(nil) }
        }
        guard active == nil, !model.isTerminating, let next = requests.first(where: { !handled.contains($0.id) }) else { return }
        present(next)
    }

    private func present(_ request: WorktreeRemovalRequest) {
        let alert = NSAlert()
        alert.messageText = "End “\(request.sessionTitle)” and remove its worktree?"
        alert.informativeText = Self.message(request)
        alert.alertStyle = request.lost.isEmpty ? .informational : .warning
        alert.addButton(withTitle: "Keep Session").keyEquivalent = "\r"
        let remove = alert.addButton(withTitle: "End Session and Remove")
        remove.hasDestructiveAction = true; remove.keyEquivalent = ""
        active = (request, alert)
        handled.insert(request.id)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn: self?.finish(request, approve: false)
                case .alertSecondButtonReturn: self?.finish(request, approve: true)
                default: self?.finish(request, approve: nil)
                }
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
        guard let active else { return }
        active.alert.window.orderOut(nil)
        finish(active.request, approve: button.tag == 1)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let active { finish(active.request, approve: false) }
        return true
    }

    /// Sends the answer, or nothing when the prompt was dismissed because the request is gone.
    private func finish(_ request: WorktreeRemovalRequest, approve: Bool?) {
        guard active?.request.id == request.id else { return }
        active = nil
        if let approve {
            Task { [weak self, model] in
                do {
                    _ = try await model.call("answerWorktreeRemoval", .object(["requestID": .string(request.id.uuidString), "approve": .bool(approve)]))
                } catch {
                    // An answer that never reached the runtime leaves the request pending: ask again once it is listed.
                    self?.handled.remove(request.id)
                    model.error = error.localizedDescription
                }
                try? await model.refresh()
                self?.update(model.snapshot.worktreeRemovalRequests ?? [])
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.update(self?.model.snapshot.worktreeRemovalRequests ?? []) }
        }
    }

    static func message(_ request: WorktreeRemovalRequest) -> String {
        var lines = ["The agent asked to remove the worktree it is working in. Its session ends, and the checkout at \(request.path) is deleted."]
        if let outcome = request.branchOutcome { lines.append(outcome) }
        if request.lost.isEmpty { lines.append("Nothing is lost.") }
        else { lines.append("This loses:\n" + request.lost.map { "• \($0)" }.joined(separator: "\n")) }
        lines.append("If you keep the session, the agent keeps running and the worktree stays.")
        lines.append("You can turn off this question in Settings › Runtime.")
        return lines.joined(separator: "\n\n")
    }
}
