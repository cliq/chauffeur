import AppKit
import SwiftUI

/// Bring the hosting window to the current Space when it is shown, instead of switching to the Space where it last appeared.
struct ActiveSpaceWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.configure() }

    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard let window else { return }
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}
