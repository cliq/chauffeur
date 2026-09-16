import Foundation

/// One menu entry per project with a live execution, including idle agent turns.
public struct ActiveProject: Equatable, Sendable {
    public let name: String
    public let sessionCount: Int
    public let route: SessionRoute

    public static func entries(projects: [Project], sessions: [Session], windows: [WindowState]) -> [ActiveProject] {
        let live = Dictionary(grouping: sessions.filter(\.state.isLive), by: \.projectID)
        return projects.compactMap { project in
            guard let sessions = live[project.id], !sessions.isEmpty else { return nil }
            let selected = windows.first { $0.id == project.id }?.selectedSessionID
            let target = sessions.first { $0.id == selected } ?? sessions.sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }[0]
            return ActiveProject(name: project.name, sessionCount: sessions.count,
                                 route: SessionRoute(projectID: project.id, sessionID: target.id))
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.route.projectID.uuidString < $1.route.projectID.uuidString : order == .orderedAscending
        }
    }
}
