import SwiftUI
import ChauffeurCore

/// Confirms a worktree removal with a checklist instead of prose: each fact
/// about the checkout is one line, green when nothing is lost and red when
/// something is. The path and the mechanism stay out of the way.
struct WorktreeDeletionSheet: View {
    let row: CheckoutRow
    let preview: WorktreeDeletionPreview
    let confirm: () -> Void
    let cancel: () -> Void

    private var items: [WorktreeDeletionPreview.Item] {
        preview.items(branch: row.branch, finishedSessions: row.sessions.count, checkoutMissing: row.finished)
    }
    private var losesSomething: Bool { items.contains { $0.severity == .loss } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Delete \(row.title)?").font(.title3).fontWeight(.semibold)
                Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    Label { Text(item.text) } icon: { icon(for: item.severity) }
                        .accessibilityIdentifier("worktreeDeletion.item.\(item.severity == .loss ? "loss" : item.severity == .safe ? "safe" : "note")")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                Button("Delete Worktree", role: .destructive) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .tint(losesSomething ? .red : nil)
                    .accessibilityIdentifier("worktreeDeletion.confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("worktreeDeletion.sheet")
    }

    @ViewBuilder private func icon(for severity: WorktreeDeletionPreview.Severity) -> some View {
        switch severity {
        case .safe: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .loss: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .note: Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
    }
}
