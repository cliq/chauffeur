import Foundation
import Testing
@testable import ChauffeurCore

struct GitRefTests {
    @Test func filteringRanksExactThenPrefixThenSubstringAndUsesRecencyForTies() {
        let names = ["z/task", "task-extra", "task", "a/task"]
        let refs = names.enumerated().map { index, name in
            GitRef(kind: .local, fullName: "refs/heads/" + name, sha: "abc12345", lastCommitDate: Date(timeIntervalSince1970: Double(index)))
        }
        #expect(GitRef.filtered(refs, query: "TASK").map(\.name) == ["task", "task-extra", "a/task", "z/task"])
        #expect(GitRef.filtered(refs, query: "not-found").isEmpty)
    }

    @Test func treeKeepsNestedFoldersAndCountsAllDescendants() {
        let refs = ["feature/z", "feature/bodyscan/b", "feature/bodyscan/a", "backup-a", "Backup/z"].map {
            GitRef(kind: .local, fullName: "refs/heads/" + $0, sha: "abc12345")
        }
        let nodes = GitRefNode.tree(refs, namespace: "local")
        #expect(nodes.map(\.name) == ["Backup", "backup-a", "feature"])
        #expect(nodes.last?.count == 3)
        #expect(nodes.last?.children?.first?.id == "local:feature/bodyscan")
        #expect(nodes.last?.children?.first?.children?.map(\.name) == ["a", "b"])
    }
}
