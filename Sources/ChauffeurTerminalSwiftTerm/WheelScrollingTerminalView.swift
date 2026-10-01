#if canImport(UIKit)
import UIKit
@preconcurrency import SwiftTerm

/// SwiftTerm's iOS view turns a pan into arrow keys (or a mouse drag) whenever the application
/// tracks the mouse, and tmux always does. That leaves no way to scroll. This subclass gives a
/// vertical pan the desktop's scroll-wheel meaning: one wheel event per cell row, sent to tmux,
/// which then scrolls its own history in copy mode. SwiftTerm's pan recognizers are made to wait
/// for this one to fail, so they still handle selection drags and plain scrolling when mouse
/// tracking is off.
///
/// The adapter turns SwiftTerm's mouse reporting off so pans stay local, which also stops taps
/// from reaching the program. While the program tracks the mouse, a tap is sent as a left click
/// too, so click targets such as Claude Code's "Jump to bottom" work. It waits for a double tap
/// to fail, as SwiftTerm's own single tap does, and a tap on a link opens the link menu instead.
@MainActor
final class WheelScrollingTerminalView: TerminalView, UIGestureRecognizerDelegate {
    private var wheelPan: UIPanGestureRecognizer?
    private var accumulatedTranslation: CGFloat = 0
    private let clickTap = UITapGestureRecognizer()
    private var linkMenu: TerminalLinkMenu?

    override init(frame: CGRect, font: UIFont?) {
        super.init(frame: frame, font: font)
        installGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installGestures()
    }

    private func installGestures() {
        installWheelPan()
        installClickTap()
        // After the click tap, so it also waits for a tap on a link to fail.
        linkMenu = TerminalLinkMenu(view: self)
    }

    private func installClickTap() {
        clickTap.addTarget(self, action: #selector(handleClickTap(_:)))
        clickTap.delegate = self
        for existing in gestureRecognizers ?? [] {
            if let other = existing as? UITapGestureRecognizer, other.numberOfTapsRequired == 2 { clickTap.require(toFail: other) }
        }
        super.addGestureRecognizer(clickTap)
    }

    /// SwiftTerm's single tap still runs beside the click: it focuses the terminal and clears a selection.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === clickTap
    }

    @objc private func handleClickTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let terminal = getTerminal()
        let cell = touchCellSize
        guard terminal.cols > 0, terminal.rows > 0, cell.width > 0, cell.height > 0 else { return }
        let point = gesture.location(in: self)
        let col = min(terminal.cols - 1, max(0, Int(point.x / cell.width)))
        let row = min(terminal.rows - 1, max(0, Int((point.y - contentOffset.y) / cell.height)))
        for release in [false, true] {
            let flags = terminal.encodeButton(button: 0, release: release, shift: false, meta: false, control: false)
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
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
        if gestureRecognizer === clickTap { return getTerminal().mouseMode != .off }
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

extension TerminalView {
    /// SwiftTerm's cell size, which it keeps private: the content is one cell per column wide,
    /// and a row is the font's line height snapped up to the pixel grid.
    var touchCellSize: CGSize {
        let font = font as CTFont
        let scale = UIScreen.main.scale
        let line = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
        return CGSize(width: contentSize.width / CGFloat(max(1, getTerminal().cols)), height: ceil(line * scale) / scale)
    }
}
#endif
