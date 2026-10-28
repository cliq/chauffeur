import Foundation

/// A stored Repositories sidebar entry: a repository by folder ID, or a group.
public enum RepositoryNode: Codable, Equatable, Identifiable, Sendable {
    case repository(UUID)
    case group(RepositoryGroup)
    public var id: UUID {
        switch self {
        case .repository(let id): id
        case .group(let group): group.id
        }
    }
    private enum CodingKeys: String, CodingKey { case repository, group }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .repository) { self = .repository(id) }
        else { self = .group(try container.decode(RepositoryGroup.self, forKey: .group)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .repository(let id): try container.encode(id, forKey: .repository)
        case .group(let group): try container.encode(group, forKey: .group)
        }
    }
    /// Whether this entry is, or encloses, `id`.
    func contains(_ id: UUID) -> Bool {
        switch self {
        case .repository(let own): own == id
        case .group(let group): group.id == id || group.items.contains { $0.contains(id) }
        }
    }
}

/// A sidebar folder gathering repositories and other groups. It holds no paths of its own.
public struct RepositoryGroup: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var items: [RepositoryNode] = []
    public init(name: String) { self.name = name }
}

/// A Repositories sidebar entry as displayed: registered repositories only.
public enum RepositoryLayoutItem: Equatable, Identifiable, Sendable {
    case repository(ProjectFolder)
    case group(id: UUID, name: String, items: [RepositoryLayoutItem])
    public var id: UUID {
        switch self {
        case .repository(let folder): folder.id
        case .group(let id, _, _): id
        }
    }
}

/// A group as menus list it: depth first, indented by `depth`.
public struct RepositoryGroupEntry: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var depth: Int
}

/// Where a moved sidebar entry lands, relative to another entry's ID.
public enum RepositoryDestination: Equatable, Sendable {
    case before(UUID)
    case after(UUID)
    /// At the end of a group.
    case into(UUID)
    /// At the end of the top level.
    case end
}

/// Sidebar order and grouping. Each change also reorders `folders` to match,
/// so clients that list folders flat show the sidebar's order.
extension Project {
    /// Registered repositories and groups as the sidebar lists them.
    public var repositoryLayout: [RepositoryLayoutItem] {
        let registered = Dictionary(folders.filter(\.registered).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func items(_ nodes: [RepositoryNode]) -> [RepositoryLayoutItem] {
            nodes.compactMap { node in
                switch node {
                case .repository(let id): registered[id].map { .repository($0) }
                case .group(let group): .group(id: group.id, name: group.name, items: items(group.items))
                }
            }
        }
        return items(normalizedRepositoryTree)
    }
    /// Every group, depth first.
    public var repositoryGroups: [RepositoryGroupEntry] {
        func groups(_ nodes: [RepositoryNode], depth: Int) -> [RepositoryGroupEntry] {
            nodes.flatMap { node -> [RepositoryGroupEntry] in
                guard case .group(let group) = node else { return [] }
                return [RepositoryGroupEntry(id: group.id, name: group.name, depth: depth)] + groups(group.items, depth: depth + 1)
            }
        }
        return groups(repositoryTree ?? [], depth: 0)
    }
    /// The groups enclosing an entry, outermost first; empty at the top level.
    public func repositoryGroupPath(to id: UUID) -> [UUID] {
        func path(_ nodes: [RepositoryNode]) -> [UUID]? {
            for node in nodes {
                if node.id == id { return [] }
                if case .group(let group) = node, let inner = path(group.items) { return [group.id] + inner }
            }
            return nil
        }
        return path(repositoryTree ?? []) ?? []
    }
    /// Adds an empty group at the end of the top level, or of `parent`, and returns its ID.
    @discardableResult
    public mutating func addRepositoryGroup(named name: String, in parent: UUID? = nil) -> UUID {
        let group = RepositoryGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        updateRepositoryTree { tree in
            if let parent, tree.updateGroup(parent, { $0.items.append(.group(group)) }) { return }
            tree.append(.group(group))
        }
        return group.id
    }
    public mutating func renameRepositoryGroup(_ id: UUID, to name: String) {
        updateRepositoryTree { _ = $0.updateGroup(id) { $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines) } }
    }
    /// Removes a group; what it held takes its place.
    public mutating func removeRepositoryGroup(_ id: UUID) {
        updateRepositoryTree { $0.dissolveGroup(id) }
    }
    /// Moves a repository or group. A group never moves into itself or a group it holds.
    public mutating func moveRepositoryItem(_ id: UUID, to destination: RepositoryDestination) {
        updateRepositoryTree { tree in
            var changed = tree
            guard let node = changed.remove(id) else { return }
            switch destination {
            case .before(let target), .after(let target), .into(let target):
                guard !node.contains(target), changed.insert(node, destination) else { return }
            case .end:
                changed.append(node)
            }
            tree = changed
        }
    }
    func validateRepositoryTree() throws {
        func groups(_ nodes: [RepositoryNode]) -> [RepositoryGroup] {
            nodes.flatMap { node -> [RepositoryGroup] in
                guard case .group(let group) = node else { return [] }
                return [group] + groups(group.items)
            }
        }
        let all = groups(repositoryTree ?? [])
        try Validation.unique(all.map(\.id), field: "repository group ID")
        // Moves address groups and repositories by ID alike.
        try Validation.require(Set(all.map(\.id)).isDisjoint(with: folders.map(\.id)), "Repository group IDs must differ from folder IDs")
        for group in all { try Validation.name(group.name) }
    }
    /// The stored tree without unknown or repeated folders, followed by the
    /// folders it lacks, such as ones added since, in `folders` order.
    private var normalizedRepositoryTree: [RepositoryNode] {
        let known = Set(folders.map(\.id))
        var seen = Set<UUID>()
        func clean(_ nodes: [RepositoryNode]) -> [RepositoryNode] {
            nodes.compactMap { node in
                switch node {
                case .repository(let id): return known.contains(id) && seen.insert(id).inserted ? node : nil
                case .group(var group): group.items = clean(group.items); return .group(group)
                }
            }
        }
        let tree = clean(repositoryTree ?? [])
        return tree + folders.filter { !seen.contains($0.id) }.map { .repository($0.id) }
    }
    private mutating func updateRepositoryTree(_ change: (inout [RepositoryNode]) -> Void) {
        var tree = normalizedRepositoryTree
        change(&tree)
        repositoryTree = tree
        let rank = Dictionary(tree.repositoryIDs.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        folders = folders.enumerated()
            .sorted { (rank[$0.element.id] ?? .max, $0.offset) < (rank[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
    }
}

private extension Array where Element == RepositoryNode {
    var repositoryIDs: [UUID] {
        flatMap { node -> [UUID] in
            switch node {
            case .repository(let id): [id]
            case .group(let group): group.items.repositoryIDs
            }
        }
    }
    mutating func remove(_ id: UUID) -> RepositoryNode? {
        if let index = firstIndex(where: { $0.id == id }) { return remove(at: index) }
        for index in indices {
            guard case .group(var group) = self[index], let node = group.items.remove(id) else { continue }
            self[index] = .group(group)
            return node
        }
        return nil
    }
    mutating func insert(_ node: RepositoryNode, _ destination: RepositoryDestination) -> Bool {
        switch destination {
        case .before(let target):
            if let index = firstIndex(where: { $0.id == target }) { insert(node, at: index); return true }
        case .after(let target):
            if let index = firstIndex(where: { $0.id == target }) { insert(node, at: index + 1); return true }
        case .into(let target):
            if updateGroup(target, { $0.items.append(node) }) { return true }
            return false
        case .end:
            append(node); return true
        }
        for index in indices {
            guard case .group(var group) = self[index], group.items.insert(node, destination) else { continue }
            self[index] = .group(group)
            return true
        }
        return false
    }
    mutating func updateGroup(_ id: UUID, _ change: (inout RepositoryGroup) -> Void) -> Bool {
        for index in indices {
            guard case .group(var group) = self[index] else { continue }
            if group.id == id { change(&group) }
            else if !group.items.updateGroup(id, change) { continue }
            self[index] = .group(group)
            return true
        }
        return false
    }
    mutating func dissolveGroup(_ id: UUID) {
        if let index = firstIndex(where: { $0.id == id }), case .group(let group) = self[index] {
            replaceSubrange(index...index, with: group.items)
            return
        }
        for index in indices {
            guard case .group(var group) = self[index] else { continue }
            group.items.dissolveGroup(id)
            self[index] = .group(group)
        }
    }
}
