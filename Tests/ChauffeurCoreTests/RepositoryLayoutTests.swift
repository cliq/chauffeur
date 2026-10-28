import Foundation
import Testing
@testable import ChauffeurCore

struct RepositoryLayoutTests {
    private func project(_ names: String...) -> Project {
        var value = Project(name: "P", presetSetID: UUID())
        for name in names { value.addFolder(ProjectFolder(path: "/tmp/\(name)")) }
        return value
    }
    private func id(_ project: Project, _ name: String) -> UUID { project.folders.first { $0.name == name }!.id }
    /// The sidebar as text: `a` for a repository, `G[a b]` for a group.
    private func outline(_ project: Project) -> String { outline(project.repositoryLayout) }
    private func outline(_ items: [RepositoryLayoutItem]) -> String {
        items.map { item in
            switch item {
            case .repository(let folder): folder.name
            case .group(_, let name, let items): "\(name)[\(outline(items))]"
            }
        }.joined(separator: " ")
    }

    @Test func projectsSavedBeforeGroupsDecodeInFolderOrder() throws {
        var json = try JSONSerialization.jsonObject(with: JSONCoding.encode(project("a", "b"))) as! [String: Any]
        json.removeValue(forKey: "repositoryTree")
        let decoded = try JSONCoding.decode(Project.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.repositoryTree == nil)
        #expect(outline(decoded) == "a b")
    }

    @Test func nestedGroupsSurviveEncoding() throws {
        var value = project("a", "b")
        let outer = value.addRepositoryGroup(named: " Work ")
        let inner = value.addRepositoryGroup(named: "Clients", in: outer)
        value.moveRepositoryItem(id(value, "b"), to: .into(inner))
        let decoded = try JSONCoding.decode(Project.self, from: JSONCoding.encode(value))
        #expect(outline(decoded) == "a Work[Clients[b]]")
        #expect(decoded.repositoryGroupPath(to: id(value, "b")) == [outer, inner])
        #expect(decoded.repositoryGroups.map(\.depth) == [0, 1])
        try decoded.validate()
    }

    @Test func movesLandBeforeAfterOrIntoTheTarget() {
        var value = project("a", "b", "c")
        let group = value.addRepositoryGroup(named: "G")
        value.moveRepositoryItem(id(value, "c"), to: .before(id(value, "a")))
        #expect(outline(value) == "c a b G[]")
        value.moveRepositoryItem(id(value, "c"), to: .into(group))
        value.moveRepositoryItem(id(value, "a"), to: .after(id(value, "c")))
        #expect(outline(value) == "b G[c a]")
        // Dropping beside an item outside the group takes a repository out of it.
        value.moveRepositoryItem(id(value, "c"), to: .before(id(value, "b")))
        value.moveRepositoryItem(id(value, "a"), to: .after(group))
        #expect(outline(value) == "c b G[] a")
        value.moveRepositoryItem(group, to: .before(id(value, "c")))
        value.moveRepositoryItem(id(value, "c"), to: .end)
        #expect(outline(value) == "G[] b a c")
    }

    @Test func foldersFollowTheSidebarOrder() {
        var value = project("a", "b", "c")
        let group = value.addRepositoryGroup(named: "G")
        value.moveRepositoryItem(id(value, "c"), to: .into(group))
        value.moveRepositoryItem(group, to: .before(id(value, "a")))
        #expect(value.folders.map(\.name) == ["c", "a", "b"])
    }

    @Test func groupsCannotMoveIntoThemselves() {
        var value = project("a")
        let outer = value.addRepositoryGroup(named: "Outer")
        let inner = value.addRepositoryGroup(named: "Inner", in: outer)
        value.moveRepositoryItem(id(value, "a"), to: .into(inner))
        let before = value
        value.moveRepositoryItem(outer, to: .into(inner))
        value.moveRepositoryItem(outer, to: .before(id(value, "a")))
        value.moveRepositoryItem(outer, to: .into(outer))
        #expect(value == before)
        value.moveRepositoryItem(inner, to: .end)
        #expect(outline(value) == "Outer[] Inner[a]")
    }

    @Test func removingAGroupLeavesWhatItHeldInItsPlace() {
        var value = project("a", "b", "c")
        let outer = value.addRepositoryGroup(named: "Outer")
        let inner = value.addRepositoryGroup(named: "Inner", in: outer)
        value.moveRepositoryItem(outer, to: .before(id(value, "c")))
        value.moveRepositoryItem(id(value, "a"), to: .into(outer))
        value.moveRepositoryItem(id(value, "b"), to: .into(inner))
        value.renameRepositoryGroup(inner, to: "Nested")
        #expect(outline(value) == "Outer[Nested[b] a] c")
        value.removeRepositoryGroup(outer)
        #expect(outline(value) == "Nested[b] a c")
    }

    @Test func newAndUnregisteredRepositoriesFitAroundTheStoredTree() {
        var value = project("a", "b")
        let group = value.addRepositoryGroup(named: "G")
        value.moveRepositoryItem(id(value, "a"), to: .into(group))
        value.addFolder(ProjectFolder(path: "/tmp/c"))
        #expect(outline(value) == "b G[a] c")
        value.folders[value.folders.firstIndex { $0.name == "a" }!].registered = false
        #expect(outline(value) == "b G[] c")
        // A folder registered again returns to where it was.
        value.addFolder(ProjectFolder(path: "/tmp/a"))
        #expect(outline(value) == "b G[a] c")
    }

    @Test func groupIDsMustDifferFromFolderIDs() throws {
        var value = project("a")
        var group = RepositoryGroup(name: "G")
        group.id = value.folders[0].id
        value.repositoryTree = [.group(group)]
        #expect(throws: (any Error).self) { try value.validate() }
    }
}
