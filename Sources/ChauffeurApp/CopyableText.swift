import SwiftUI
import AppKit

/// Text that copies `value` to the clipboard when clicked and confirms with a
/// short "Copied" bubble that dismisses itself.
struct CopyableText<Content: View>: View {
    let value: String
    let what: String
    @ViewBuilder let label: () -> Content
    @State private var copied = false
    @State private var dismissal: Task<Void, Never>?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(value, forType: .string) else { return }
            copied = true
            dismissal?.cancel()
            dismissal = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(value)\nClick to copy the \(what)")
        .accessibilityLabel("Copy \(what)")
        .accessibilityValue(value)
        .popover(isPresented: $copied, arrowEdge: .bottom) {
            Label("Copied \(what)", systemImage: "checkmark").font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
        }
        .pointerStyle(.link)
        .onDisappear { dismissal?.cancel() }
    }
}
