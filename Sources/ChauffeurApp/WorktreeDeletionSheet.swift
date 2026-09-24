import SwiftUI
import ChauffeurCore

/// Confirms a worktree removal with one verdict a glance can read: red with
/// the issues that lose work, or green with the reasons nothing is lost. The
/// two are never mixed in one list. Branch bookkeeping and finished session
/// history removal are footnotes.
struct WorktreeDeletionSheet: View {
    let row: CheckoutRow
    let preview: WorktreeDeletionPreview
    let confirm: () -> Void
    let cancel: () -> Void

    private var items: [WorktreeDeletionPreview.Item] {
        preview.items(branch: row.branch, finishedSessions: row.sessions.count, checkoutMissing: row.finished)
    }
    private var issues: [WorktreeDeletionPreview.Item] { items.filter { $0.severity == .loss } }
    private var reasons: [WorktreeDeletionPreview.Item] { items.filter { $0.severity == .safe } }
    private var notes: [WorktreeDeletionPreview.Item] { items.filter { $0.severity == .note } }
    private var losesWork: Bool { !issues.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Delete \(row.title)?").font(.title3).fontWeight(.semibold)
                Text(row.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(losesWork ? "Deleting this worktree loses work" : "Safe to delete").fontWeight(.semibold)
                } icon: {
                    Image(systemName: losesWork ? "xmark.circle.fill" : "checkmark.circle.fill")
                }
                .foregroundStyle(losesWork ? Color.red : Color.green)
                .accessibilityIdentifier(losesWork ? "worktreeDeletion.verdict.loss" : "worktreeDeletion.verdict.safe")
                ForEach(losesWork ? issues : reasons) { item in
                    Text(item.text).padding(.leading, 26)
                        .accessibilityIdentifier("worktreeDeletion.item.\(losesWork ? "loss" : "safe")")
                }
                if !row.finished, let files = preview.changedFiles, !files.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(files) { file in
                                Text(file.description)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(files.count) * 36, 180))
                    .padding(.leading, 26)
                    .accessibilityIdentifier("worktreeDeletion.changedFiles")
                }
            }
            if !notes.isEmpty {
                Text(notes.map(\.text).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                Button("Delete Worktree", role: .destructive) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .tint(losesWork ? .red : nil)
                    .accessibilityIdentifier("worktreeDeletion.confirm")
            }
        }
        .padding(20)
        .frame(width: 460)
        .accessibilityIdentifier("worktreeDeletion.sheet")
    }
}
