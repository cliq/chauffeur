import AppKit
import SwiftUI

/// Keep a scroll track visible in bounded folder lists, including with a trackpad.
struct PersistentScrollbars: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollbarAnchor { ScrollbarAnchor() }
    func updateNSView(_ view: ScrollbarAnchor, context: Context) { view.configure() }

    final class ScrollbarAnchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard let scroll = enclosingScrollView else { return }
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = false
            scroll.scrollerStyle = .legacy
        }
    }
}
