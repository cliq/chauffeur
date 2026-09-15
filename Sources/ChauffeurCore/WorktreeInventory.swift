import Foundation

public struct GitWorktree: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var commit: String
    public var branch: String
    public var locked: Bool
    public var prunable: Bool
    public var gitIdentity: UUID?
    public var availability: Availability?
    public var id: String { path }
    public init(path: String, commit: String, branch: String, locked: Bool, prunable: Bool) {
        self.path = path; self.commit = commit; self.branch = branch; self.locked = locked; self.prunable = prunable
    }
}

public struct RepositoryInventory: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case available, notRepository, missing, inaccessible, failed }
    public var sourcePath: String
    public var sourcePaths: [String]?
    public var repositoryID: UUID?
    public var entries: [GitWorktree] = []
    public var observedAt = Date()
    public var status: Status
    public var error: ChauffeurError?
    public init(sourcePath: String, status: Status) { self.sourcePath = sourcePath; self.status = status }
}
