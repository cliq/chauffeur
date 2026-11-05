import SwiftUI
import ChauffeurCore

/// Confirms a worktree removal with one verdict a glance can read: red with
/// the issues that lose work, or green with the reasons nothing is lost. The
/// two are never mixed in one list. A merged branch is deleted unless the
/// person unticks it; one with unmerged commits is kept unless they tick it,
/// and its unpushed commits only count as lost once they do.
/// Finished session history removal is a footnote.
struct WorktreeDeletionSheet: View {
    /// What happens to the checkout's branch.
    struct BranchChoice {
        /// Leave the branch even when nothing else needs its commits.
        var keep: Bool
        /// Delete the branch even when its commits exist nowhere else.
        var force: Bool
    }
    let row: CheckoutRow
    let preview: WorktreeDeletionPreview
    let confirm: (BranchChoice) -> Void
    let cancel: () -> Void
    @State private var deleteBranch: Bool

    init(row: CheckoutRow, preview: WorktreeDeletionPreview, confirm: @escaping (BranchChoice) -> Void, cancel: @escaping () -> Void) {
        self.row = row; self.preview = preview; self.confirm = confirm; self.cancel = cancel
        _deleteBranch = State(initialValue: preview.deletesBranchByDefault)
    }

    private var items: [WorktreeDeletionPreview.Item] {
        preview.items(branch: row.branch, finishedSessions: row.sessions.count, checkoutMissing: row.finished, deletingBranch: deletesBranch)
    }
    private var issues: [WorktreeDeletionPreview.Item] { items.filter { $0.severity == .loss } }
    private var reasons: [WorktreeDeletionPreview.Item] { items.filter { $0.severity == .safe } }
    private var notes: [WorktreeDeletionPreview.Item] { items.filter { $0.severity == .note } }
    private var losesWork: Bool { !issues.isEmpty }
    private var deletesBranch: Bool { deleteBranch && preview.offersBranchDeletion(branch: row.branch, checkoutMissing: row.finished) }

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
            if let note = row.note {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Its note is deleted too", systemImage: "note.text").font(.caption).fontWeight(.medium)
                    Text(note.text).font(.caption).lineLimit(6).textSelection(.enabled)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("worktreeDeletion.note")
            }
            if preview.offersBranchDeletion(branch: row.branch, checkoutMissing: row.finished) {
                // The verdict above follows this choice, so ticking it on an
                // unpushed branch turns the sheet red with the commits lost.
                Toggle(isOn: $deleteBranch) { Text("Delete branch \(Text(row.branch).fontWeight(.medium))") }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("worktreeDeletion.deleteBranch")
            }
            if !notes.isEmpty {
                Text(notes.map(\.text).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }.keyboardShortcut(.cancelAction)
                Button("Delete Worktree", role: .destructive) {
                    confirm(BranchChoice(keep: !deletesBranch, force: deletesBranch && !preview.deletesBranchByDefault))
                }
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
