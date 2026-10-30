import SwiftUI
import ChauffeurRemoteProtocol

/// A branch name, always with the branch glyph and in monospace so it never reads as a folder.
struct BranchText: View {
    let branch: String
    var font: Font = .subheadline

    var body: some View {
        Label {
            Text(branch)
                .font(font.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "arrow.triangle.branch")
                .font(font)
                .foregroundStyle(.secondary)
        }
        .labelStyle(BranchLabelStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Branch \(branch)")
    }
}

private struct BranchLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// A checkout as two separate facts: the branch checked out in it, and where it
/// lives, the repository's main checkout or a worktree folder beside it.
struct CheckoutLabel: View {
    let kind: CheckoutKind
    let branch: String
    /// The checkout's folder, named for worktrees whose folder differs from their branch.
    var path: String?
    var isRepository = true
    var unavailable = false
    /// The checkout's note, previewed so a parked worktree says where to resume.
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(kind: kind, isRepository: isRepository))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                if isRepository {
                    BranchText(branch: branch)
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note {
                        Label(note, systemImage: "note.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(unavailable ? "Folder · Unavailable" : "Folder")
                        .font(.subheadline)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The Mac sidebar uses a branch icon for worktrees; here the branch glyph
    /// belongs to the branch name, so worktrees get a second-copy icon instead.
    static func symbol(kind: CheckoutKind, isRepository: Bool) -> String {
        guard isRepository else { return "folder" }
        return kind == .main ? "house" : "rectangle.portrait.on.rectangle.portrait"
    }

    private var location: String {
        var parts = [kind == .main ? "Main checkout" : "Worktree"]
        if kind == .worktree, let path {
            let folder = URL(fileURLWithPath: path).lastPathComponent
            if folder != branch.replacingOccurrences(of: "/", with: "-") { parts.append(folder) }
        }
        if unavailable { parts.append("Unavailable") }
        return parts.joined(separator: " · ")
    }
}

/// Where a session runs, on one line: repository, branch, and whether that is the main checkout or a worktree.
struct SessionLocationLine: View {
    var repository: String?
    let branch: String?
    let kind: CheckoutKind
    var isRepository = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // The branch says more than the repository, so the repository name gives way first.
            if let repository {
                Text(repository)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if isRepository, let branch {
                if repository != nil { Text("·").foregroundStyle(.tertiary) }
                BranchText(branch: branch, font: .caption)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
            }
            CheckoutKindTag(text: !isRepository ? "Folder" : kind == .main ? "Main" : "Worktree")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([repository, isRepository ? branch.map { "branch \($0)" } : nil,
                             !isRepository ? "folder" : kind == .main ? "main checkout" : "worktree"].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A small uppercase tag naming the kind of checkout.
struct CheckoutKindTag: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}
