#if canImport(UIKit)
import UIKit
@preconcurrency import SwiftTerm

/// Tapping a link offers Open Link and Copy Link in the system edit menu.
///
/// SwiftTerm's iOS view opens a tapped link only while a pointer hovers over it, so on a touch
/// screen links do nothing. This tap recognizer begins only when the touch lands on a link, an
/// OSC 8 hyperlink's target or a URL in the text; SwiftTerm's own single tap waits for it to fail,
/// so a tap anywhere else still focuses the terminal or reaches tmux, and a tap on a link does
/// neither. Like SwiftTerm's single tap, it waits for a double tap to fail, so double-tapping a
/// link still selects it.
@MainActor
final class TerminalLinkMenu: NSObject, UIGestureRecognizerDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    private weak var view: TerminalView?
    private let tap = UITapGestureRecognizer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    /// The link under the current tap, then the one the presented menu acts on.
    private var link: String?

    init(view: TerminalView) {
        self.view = view
        super.init()
        view.addInteraction(editMenu)
        tap.addTarget(self, action: #selector(handleTap(_:)))
        tap.delegate = self
        for existing in view.gestureRecognizers ?? [] {
            guard let other = existing as? UITapGestureRecognizer else { continue }
            if other.numberOfTapsRequired == 1 { other.require(toFail: tap) }
            if other.numberOfTapsRequired == 2 { tap.require(toFail: other) }
        }
        view.addGestureRecognizer(tap)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        link = linkAt(gestureRecognizer.location(in: view))
        return link != nil
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, link != nil else { return }
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: gesture.location(in: view)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let link else { return nil }
        var actions: [UIMenuElement] = []
        if let scheme = URL(string: link)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            actions.append(UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { [weak self] _ in self?.open(link) })
        }
        actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in UIPasteboard.general.string = link })
        return UIMenu(children: actions)
    }

    /// Through the terminal delegate, which keeps the adapter's scheme filter.
    private func open(_ link: String) {
        guard let view else { return }
        view.terminalDelegate?.requestOpenLink(source: view, link: link, params: [:])
    }

    /// The link at a point in the view's content, which scrolls with the buffer.
    private func linkAt(_ point: CGPoint) -> String? {
        guard let view else { return nil }
        let terminal = view.getTerminal()
        let cell = view.touchCellSize
        guard terminal.cols > 0, cell.width > 0, cell.height > 0, point.x >= 0, point.y >= 0 else { return nil }
        let position = Position(col: min(terminal.cols - 1, Int(point.x / cell.width)), row: Int(point.y / cell.height))
        return terminal.link(at: .buffer(position), mode: .explicitAndImplicit)
    }
}
#endif
