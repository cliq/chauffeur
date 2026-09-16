import AppKit
import Combine

/// One native owner for shared model errors, regardless of how many windows
/// observe the model. Distinct errors wait their turn; repeated ones coalesce.
@MainActor final class AppErrorPresenter {
    private let model: AppModel
    private var subscription: AnyCancellable?
    private var pending: [String] = []
    private var activeMessage: String?

    init(model: AppModel) {
        self.model = model
        subscription = model.$error.sink { [weak self] message in
            // Published values arrive before the property itself changes.
            Task { @MainActor [weak self] in
                guard let self, let message else { return }
                guard self.activeMessage != message, !self.pending.contains(message) else { return }
                self.pending.append(message)
                self.presentNext()
            }
        }
    }

    private func presentNext() {
        guard activeMessage == nil, !pending.isEmpty, !model.isTerminating else { return }
        let message = pending.removeFirst()
        activeMessage = message
        let alert = NSAlert()
        alert.messageText = "Chauffeur"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] _ in
            guard let self else { return }
            self.activeMessage = nil
            if self.model.error == message { self.model.error = nil }
            DispatchQueue.main.async { [weak self] in self?.presentNext() }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
