import SwiftUI

/// Shared badge treatment for agent types on macOS and iOS.
struct AgentBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

extension AgentBadge {
    /// The colour for a provider's `badgeColorName`; gray when unknown.
    static func color(named name: String?) -> Color {
        switch name {
        case "orange": .orange
        case "blue": .blue
        case "teal": .teal
        default: .gray
        }
    }
}
