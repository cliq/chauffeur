import Foundation

public struct FolderRoute: Equatable, Sendable {
    public let path: String
    public init(path: String) { self.path = path }
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "chauffeur", parts.host == "open", parts.user == nil,
              parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty, let items = parts.queryItems, items.count == 1,
              items[0].name == "path", let path = items[0].value,
              path.hasPrefix("/"), !path.contains("\0") else { return nil }
        self.path = path
    }
    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "chauffeur"; parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "path", value: path)]
        return parts.url!
    }
}

public struct ProjectFolderMatch: Equatable, Identifiable, Sendable {
    public let projectID: UUID
    public let folderID: UUID
    public let path: String
    public var id: UUID { projectID }
}

public enum ProjectFolderResolver {
    /// Prefer the closest registered ancestor. Equal matches across projects
    /// remain ambiguous so the caller can present a choice.
    public static func matches(path: String, projects: [Project], worktrees: [Worktree], inventories: [RepositoryInventory] = []) -> [ProjectFolderMatch] {
        let requested = Paths.canonical(path)
        var matches: [ProjectFolderMatch] = []
        for project in projects {
            var best: ProjectFolderMatch?
            for folder in project.folders where folder.registered {
                var paths = [folder.canonicalPath]
                paths += worktrees.filter { $0.projectID == project.id && $0.folderID == folder.id && $0.registered && $0.availability == .available }.map(\.path)
                for inventory in inventories where inventory.sourcePath == folder.canonicalPath || inventory.sourcePaths?.contains(folder.canonicalPath) == true {
                    paths += inventory.entries.filter { $0.availability == nil || $0.availability == .available }.map(\.path)
                }
                for candidate in paths.map(Paths.canonical) {
                    guard requested == candidate || requested.hasPrefix(candidate == "/" ? "/" : candidate + "/") else { continue }
                    if best == nil || candidate.count > best!.path.count {
                        best = ProjectFolderMatch(projectID: project.id, folderID: folder.id, path: candidate)
                    }
                }
            }
            if let best { matches.append(best) }
        }
        let longest = matches.map { $0.path.count }.max()
        return matches.filter { $0.path.count == longest }.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
    }
}
