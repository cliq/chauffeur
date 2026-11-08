import Foundation
import ChauffeurRemoteProtocol

/// Matches a new-session search across projects, repositories, and checkouts at once, so
/// "chauffeur mobile" can jump straight to a worktree.
///
/// Every word must appear somewhere in a result's project, repository, or checkout names. A
/// repository also needs a word in its own name, and a checkout in its branch or folder, so a
/// query naming only a project lists that project instead of everything inside it.
struct LaunchSearch {
    struct Repository: Identifiable {
        let project: ProjectSummary
        let folder: FolderSummary
        var id: UUID { folder.id }
    }

    struct Checkout: Identifiable {
        let project: ProjectSummary
        let folder: FolderSummary
        let checkout: CheckoutSummary
        var id: String { checkout.id }
        var location: LaunchLocation {
            LaunchLocation(projectID: project.id, folderID: folder.id, checkout: .existing(path: checkout.path))
        }
    }

    private(set) var projects: [ProjectSummary] = []
    private(set) var repositories: [Repository] = []
    private(set) var checkouts: [Checkout] = []

    var isEmpty: Bool { projects.isEmpty && repositories.isEmpty && checkouts.isEmpty }

    init(query: String, projects: [ProjectSummary]) {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return }
        for project in projects where !project.archived {
            let projectNames = [project.name]
            if Self.matches(words, all: projectNames, any: projectNames) {
                self.projects.append(project)
            }
            for folder in project.folders {
                let folderNames = [folder.name, URL(fileURLWithPath: folder.path).lastPathComponent]
                if Self.matches(words, all: projectNames + folderNames, any: folderNames) {
                    repositories.append(Repository(project: project, folder: folder))
                }
                guard folder.availability == .available else { continue }
                for checkout in folder.checkouts where checkout.availability == .available {
                    var checkoutNames = [URL(fileURLWithPath: checkout.path).lastPathComponent]
                    if folder.isRepository { checkoutNames.append(checkout.branch) }
                    // A main checkout's folder is the repository's own; it matches by branch alone.
                    let own = checkout.kind == .main ? Array(checkoutNames.dropFirst()) : checkoutNames
                    if Self.matches(words, all: projectNames + folderNames + checkoutNames, any: own) {
                        checkouts.append(Checkout(project: project, folder: folder, checkout: checkout))
                    }
                }
            }
        }
    }

    /// Every word appears in `all`, and at least one appears in `any`.
    private static func matches(_ words: [String], all: [String], any: [String]) -> Bool {
        let all = all.map { $0.lowercased() }
        let any = any.map { $0.lowercased() }
        return words.allSatisfy { word in all.contains { $0.contains(word) } }
            && words.contains { word in any.contains { $0.contains(word) } }
    }
}
