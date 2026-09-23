import SwiftUI
import ChauffeurCore

struct RefPickerRow: View {
    let name: String
    let ref: GitRef?
    let depth: Int
    let count: Int?
    let subtitle: String?
    let query: String
    let selected: Bool
    let expanded: Bool
    let isMore: Bool
    let activate: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private var stale: Bool {
        guard let ref, ref.kind == .local || ref.kind == .remote, let date = ref.lastCommitDate,
              let threshold = Calendar.current.date(byAdding: .month, value: -6, to: Date()) else { return false }
        return date < threshold
    }
    private var secondary: Color { selected ? .white.opacity(0.75) : Color(nsColor: .secondaryLabelColor) }
    private var tertiary: Color { selected ? .white.opacity(0.75) : Color(nsColor: contrast == .increased ? .secondaryLabelColor : .tertiaryLabelColor) }
    private var nameColor: Color { selected ? .white : stale || ref?.isMerged == true ? tertiary : .primary }
    private var symbol: String {
        guard let ref else { return "folder" }
        switch ref.kind {
        case .head, .commit: return "point.topleft.down.to.point.bottomright.curvepath"
        case .tag: return "tag"
        case .local, .remote: return "arrow.triangle.branch"
        }
    }
    private var age: String? {
        guard let ref, ref.kind == .tag || stale, let date = ref.kind == .tag ? ref.creatorDate : ref.lastCommitDate else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.year, .month, .day, .hour, .minute]
        formatter.maximumUnitCount = 1; formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(0, Date().timeIntervalSince(date))) ?? "now"
    }
    private var accessibilityText: String {
        guard let ref else { return isMore ? name : "\(name), folder, \(count ?? 0) refs, \(expanded ? "expanded" : "collapsed")" }
        let kind: String
        switch ref.kind { case .local: kind = "local branch"; case .remote: kind = "remote branch"; case .tag: kind = "tag"; case .head, .commit: kind = "commit" }
        return [ref.name, kind, subtitle, ref.isMerged ? "Merged" : nil, age,
                ref.isCheckedOutInWorktree ? "Checked out in a worktree" : nil, ref.isHEAD ? "HEAD" : nil,
                ref.ahead > 0 ? "\(ref.ahead) ahead" : nil, ref.behind > 0 ? "\(ref.behind) behind" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
    private var styledName: AttributedString {
        var value = AttributedString(name)
        value.foregroundColor = nameColor
        if !query.isEmpty {
            if let slash = name.lastIndex(of: "/"),
               let end = AttributedString.Index(name.index(after: slash), within: value) {
                value[value.startIndex..<end].foregroundColor = tertiary
            }
            var remaining = name.startIndex..<name.endIndex
            while let match = name.range(of: query, options: .caseInsensitive, range: remaining) {
                if let start = AttributedString.Index(match.lowerBound, within: value), let end = AttributedString.Index(match.upperBound, within: value) {
                    value[start..<end].font = .system(size: 13, weight: .bold)
                    value[start..<end].foregroundColor = selected ? .white : .accentColor
                }
                remaining = match.upperBound..<name.endIndex
            }
        }
        return value
    }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 6) {
                if !isMore {
                    Image(systemName: count == nil ? "chevron.right" : expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(secondary)
                        .opacity(count == nil ? 0 : 1).frame(width: 8)
                    if ref?.kind == .head || ref?.kind == .commit {
                        HStack(spacing: 0) {
                            Rectangle().frame(width: 4, height: 1.5)
                            Circle().stroke(lineWidth: 1.5).frame(width: 6, height: 6)
                            Rectangle().frame(width: 4, height: 1.5)
                        }.foregroundStyle(secondary).frame(width: 14)
                    } else {
                        Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(secondary).frame(width: 14)
                    }
                }
                Text(styledName).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                Spacer(minLength: 4)
                if let subtitle { Text(subtitle).lineLimit(1).truncationMode(.middle) }
                if ref?.isMerged == true { Text("Merged") }
                if let age { Text(age) }
                if ref?.isCheckedOutInWorktree == true {
                    Text("worktree").padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(secondary.opacity(0.7)))
                        .help("Checked out in a worktree")
                }
                if ref?.isHEAD == true {
                    Text("HEAD").padding(.horizontal, 4).padding(.vertical, 1)
                        .background(selected ? Color.white.opacity(0.18) : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                }
                if let ref, ref.ahead > 0 || ref.behind > 0 {
                    Text([ref.ahead > 0 ? "↑\(ref.ahead)" : nil, ref.behind > 0 ? "↓\(ref.behind)" : nil].compactMap { $0 }.joined(separator: " "))
                }
                if let count { Text("\(count)").italic() }
            }
            .font(.system(size: 11)).foregroundStyle(tertiary)
            .padding(.leading, CGFloat(8 + depth * 16)).padding(.trailing, 8).frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ref-picker.row." + (ref?.fullName ?? name))
    }
}
