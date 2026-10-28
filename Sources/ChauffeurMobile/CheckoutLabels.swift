import SwiftUI
import ChauffeurRemoteProtocol

/// A repository or plain folder, under the Mac sidebar groups that hold it.
struct RepositoryLabel: View {
    let name: String
    var isRepository = true
    /// Enclosing group names, outermost first.
    var groupPath: [String] = []

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                if !groupPath.isEmpty {
                    GroupPathText(names: groupPath)
                }
                Text(name)
                    .font(.subheadline.weight(.semibold))
            }
        } icon: {
            Image(systemName: isRepository ? "folder" : "folder.badge.questionmark")
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Work › Clients", with the groups icon the Mac sidebar uses.
struct GroupPathText: View {
    let names: [String]

    var body: some View {
        Label(names.joined(separator: " › "), systemImage: "rectangle.stack")
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel("In group \(names.joined(separator: ", "))")
    }
}

/// A checkout named by its branch, saying outright whether it is the
/// repository's main checkout or a separate worktree, with the Mac sidebar's icons.
struct CheckoutLabel: View {
    let kind: CheckoutKind
    let branch: String
    var isRepository = true
    var unavailable = false

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(isRepository ? branch : "Folder")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isRepository {
                    CheckoutKindTag(text: kind == .main ? "Main checkout" : "Worktree")
                }
                if unavailable {
                    CheckoutKindTag(text: "Unavailable")
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .accessibilityElement(children: .combine)
    }

    private var systemImage: String {
        guard isRepository else { return "folder" }
        return kind == .main ? "house" : "arrow.triangle.branch"
    }
}

private struct CheckoutKindTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}
