import Foundation

public struct GitRef: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case head, local, remote, tag, commit }
    public var kind: Kind
    public var fullName: String
    public var sha: String
    public var subject: String
    public var lastCommitDate: Date?
    public var creatorDate: Date?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var isMerged: Bool
    public var isCheckedOutInWorktree: Bool
    public var isHEAD: Bool
    public var id: String { fullName }
    public var shortSHA: String { String(sha.prefix(8)) }
    public var name: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return kind == .commit ? shortSHA : fullName
    }

    public init(kind: Kind, fullName: String, sha: String, subject: String = "", lastCommitDate: Date? = nil,
                creatorDate: Date? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                isMerged: Bool = false, isCheckedOutInWorktree: Bool = false, isHEAD: Bool = false) {
        self.kind = kind; self.fullName = fullName; self.sha = sha; self.subject = subject
        self.lastCommitDate = lastCommitDate; self.creatorDate = creatorDate; self.upstream = upstream
        self.ahead = ahead; self.behind = behind; self.isMerged = isMerged
        self.isCheckedOutInWorktree = isCheckedOutInWorktree; self.isHEAD = isHEAD
    }

    public static func isCommitQuery(_ query: String) -> Bool {
        (4...40).contains(query.utf8.count) && query.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    public static func filtered(_ refs: [GitRef], query: String) -> [GitRef] {
        let query = query.lowercased()
        func rank(_ ref: GitRef) -> Int {
            let name = ref.name.lowercased()
            return name == query ? 0 : name.hasPrefix(query) ? 1 : 2
        }
        return refs.filter { $0.name.lowercased().contains(query) }.sorted {
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.lastCommitDate != $1.lastCommitDate { return ($0.lastCommitDate ?? .distantPast) > ($1.lastCommitDate ?? .distantPast) }
            return $0.fullName < $1.fullName
        }
    }
}

public struct GitRefSnapshot: Codable, Sendable {
    public var repositoryKey: String
    public var refs: [GitRef]
    public var head: GitRef?
    public var defaultBranch: String?
    public var fetchedAt: Date?

    public init(repositoryKey: String, refs: [GitRef], head: GitRef?, defaultBranch: String?, fetchedAt: Date?) {
        self.repositoryKey = repositoryKey; self.refs = refs; self.head = head
        self.defaultBranch = defaultBranch; self.fetchedAt = fetchedAt
    }
}

public struct GitRefNode: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var ref: GitRef?
    public var children: [GitRefNode]?
    public var count: Int { children?.reduce(0) { $0 + $1.count } ?? 1 }

    public static func tree(_ refs: [GitRef], namespace: String) -> [GitRefNode] {
        func build(_ entries: [(GitRef, [String])], path: String) -> [GitRefNode] {
            let grouped = Dictionary(grouping: entries, by: { $0.1[0] })
            return grouped.keys.sorted {
                let order = $0.caseInsensitiveCompare($1)
                return order == .orderedSame ? $0 < $1 : order == .orderedAscending
            }.flatMap { name -> [GitRefNode] in
                let group = grouped[name]!
                let nextPath = path.isEmpty ? name : path + "/" + name
                var result = group.filter { $0.1.count == 1 }.map {
                    GitRefNode(id: $0.0.id, name: name, ref: $0.0, children: nil)
                }
                let nested = group.filter { $0.1.count > 1 }.map { ($0.0, Array($0.1.dropFirst())) }
                if !nested.isEmpty {
                    result.append(GitRefNode(id: namespace + ":" + nextPath, name: name, ref: nil, children: build(nested, path: nextPath)))
                }
                return result
            }
        }
        return build(refs.map { ($0, $0.name.split(separator: "/").map(String.init)) }, path: "")
    }
}
