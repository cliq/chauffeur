import AppKit
import SwiftUI

/// Plain text input for flags: macOS prose substitutions would corrupt argv.
struct ArgumentEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let editor = NSTextView()
        editor.isRichText = false; editor.importsGraphics = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textColor = .labelColor; editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text; editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Launch arguments")
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        if let editor = scroll.documentView as? NSTextView, editor.string != text { editor.string = text }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
