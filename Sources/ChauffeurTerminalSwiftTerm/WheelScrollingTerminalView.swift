#if canImport(UIKit)
import UIKit
@preconcurrency import SwiftTerm

/// SwiftTerm's iOS view turns a pan into arrow keys (or a mouse drag) whenever the application
/// tracks the mouse, and tmux always does. That leaves no way to scroll. This subclass gives a
/// vertical pan the desktop's scroll-wheel meaning: one wheel event per cell row, sent to tmux,
/// which then scrolls its own history in copy mode. SwiftTerm's pan recognizers are made to wait
/// for this one to fail, so they still handle selection drags and plain scrolling when mouse
/// tracking is off.
@MainActor
final class WheelScrollingTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private var wheelPan: UIPanGestureRecognizer?
    private var accumulatedTranslation: CGFloat = 0

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font)
        installWheelPan()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installWheelPan()
    }

    private func installWheelPan() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleWheelPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        wheelPan = pan
        // Recognizers SwiftTerm already installed, including the scroll view's own pan.
        for existing in gestureRecognizers ?? [] where existing is UIPanGestureRecognizer {
            existing.require(toFail: pan)
        }
        panGestureRecognizer.require(toFail: pan)
        super.addGestureRecognizer(pan)
    }

    /// SwiftTerm adds its mouse and selection pans lazily as terminal modes change.
    override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        if let wheelPan, gestureRecognizer !== wheelPan, gestureRecognizer is UIPanGestureRecognizer {
            gestureRecognizer.require(toFail: wheelPan)
        }
        super.addGestureRecognizer(gestureRecognizer)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === wheelPan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard getTerminal().mouseMode != .off else { return false }
        let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: self) ?? .zero
        return abs(velocity.y) > abs(velocity.x)
    }

    @objc private func handleWheelPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            accumulatedTranslation = 0
        case .changed:
            let terminal = getTerminal()
            let rows = max(1, terminal.rows)
            let cols = max(1, terminal.cols)
            let cellHeight = bounds.height / CGFloat(rows)
            let cellWidth = bounds.width / CGFloat(cols)
            guard cellHeight > 0, cellWidth > 0 else { return }
            accumulatedTranslation += gesture.translation(in: self).y
            gesture.setTranslation(.zero, in: self)
            let lines = Int(accumulatedTranslation / cellHeight)
            guard lines != 0 else { return }
            accumulatedTranslation -= CGFloat(lines) * cellHeight
            let point = gesture.location(in: self)
            let col = min(cols - 1, max(0, Int(point.x / cellWidth)))
            let row = min(rows - 1, max(0, Int((point.y - contentOffset.y) / cellHeight)))
            // Finger moving down reveals earlier output, which is wheel-up (button 4).
            let button = lines > 0 ? 4 : 5
            let flags = terminal.encodeButton(button: button, release: false, shift: false, meta: false, control: false)
            for _ in 0..<abs(lines) {
                terminal.sendEvent(buttonFlags: flags, x: col, y: row)
            }
        default:
            accumulatedTranslation = 0
        }
    }
}
#endif
