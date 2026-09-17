import SwiftUI

/// Commits waiting to be merged: the base branch on the left, the worktree's
/// branch on the right, and an arrow from the branch pointing back at the base.
/// SF Symbols' merge and pull arrows both read as changes already merged.
///
/// Everything is stroked: a filled `Shape` picks up a lighter level of the
/// row's hierarchical foreground style than a stroked one and looks faded.
struct UnmergedCommitsGlyph: View {
    var body: some View {
        ZStack {
            UnmergedLines().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            UnmergedCommits().stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
        .frame(width: 11, height: 12)
    }
}

/// The drawing stays inside this inset so round caps and dots are never clipped
/// at the frame edge.
private func canvas(_ rect: CGRect) -> CGRect { rect.insetBy(dx: 1.0, dy: 1.2) }

private struct UnmergedLines: Shape {
    func path(in rect: CGRect) -> Path {
        let rect = canvas(rect), w = rect.width, h = rect.height
        let baseX = rect.minX + w * 0.16, branchX = rect.minX + w * 0.84
        var path = Path()
        // Base branch: a line between its two commits.
        path.move(to: CGPoint(x: baseX, y: rect.minY + h * 0.3))
        path.addLine(to: CGPoint(x: baseX, y: rect.minY + h * 0.7))
        // Worktree branch rising from its commit, then turning toward the base.
        path.move(to: CGPoint(x: branchX, y: rect.minY + h * 0.7))
        path.addLine(to: CGPoint(x: branchX, y: rect.minY + h * 0.42))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.14),
                          control: CGPoint(x: branchX, y: rect.minY + h * 0.14))
        // Arrowhead pointing at the base, clear of its top commit.
        let tipX = rect.minX + w * 0.44, tipY = rect.minY + h * 0.14
        path.move(to: CGPoint(x: tipX + w * 0.18, y: tipY - h * 0.16))
        path.addLine(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: CGPoint(x: tipX + w * 0.18, y: tipY + h * 0.16))
        return path
    }
}

/// Three commits as tiny circles; the thick round stroke turns them into dots.
private struct UnmergedCommits: Shape {
    func path(in rect: CGRect) -> Path {
        let rect = canvas(rect), w = rect.width, h = rect.height, r: CGFloat = 0.5
        let baseX = rect.minX + w * 0.16, branchX = rect.minX + w * 0.84
        var path = Path()
        for center in [CGPoint(x: baseX, y: rect.minY + h * 0.14), CGPoint(x: baseX, y: rect.minY + h * 0.86), CGPoint(x: branchX, y: rect.minY + h * 0.86)] {
            path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
        return path
    }
}
