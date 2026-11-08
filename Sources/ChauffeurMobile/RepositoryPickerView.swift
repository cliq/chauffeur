import SwiftUI
import ChauffeurRemoteProtocol

/// New session, second step: the project's repositories and folders, under the Mac
/// sidebar's groups.
struct RepositoryPickerView: View {
    var model: MobileAppModel
    let projectID: UUID
    @State private var query = ""

    private var project: ProjectSummary? { model.inventory?.project(projectID) }

    var body: some View {
        Group {
            if let project {
                List {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(FolderSection.sections(of: project)) { section in
                            Section {
                                ForEach(section.folders) { folder in
                                    NavigationLink(value: model.newSessionRoute(projectID: project.id, folderID: folder.id)) {
                                        RepositoryRow(model: model, folder: folder)
                                    }
                                    .disabled(folder.availability != .available)
                                    .accessibilityIdentifier("new-session-repository")
                                }
                            } header: {
                                if let title = section.title {
                                    Label(title, systemImage: "rectangle.stack")
                                }
                            }
                        }
                    } else {
                        LaunchSearchSections(model: model, search: LaunchSearch(query: query, projects: [project]), query: query, showsProject: false)
                    }
                }
                .searchable(text: $query, prompt: "Repositories and branches", when: project.folders.count > 6)
                .overlay {
                    if project.folders.isEmpty {
                        ContentUnavailableView("No repositories", systemImage: "folder", description: Text("Add a folder to \(project.name) on your Mac."))
                    }
                }
                .navigationTitle(project.name)
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark",
                                       description: Text("It is no longer on your Mac's project list."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A run of consecutive folders in the same sidebar group.
private struct FolderSection: Identifiable {
    let id: String
    /// The group path, outermost first; nil at the top level.
    let title: String?
    var folders: [FolderSummary]

    static func sections(of project: ProjectSummary) -> [FolderSection] {
        var sections: [FolderSection] = []
        var lastKey: String?
        for folder in project.folders {
            let path = project.groupPath(of: folder)
            let key = path.map(\.id.uuidString).joined(separator: "/")
            if key == lastKey {
                sections[sections.count - 1].folders.append(folder)
            } else {
                sections.append(FolderSection(id: "\(sections.count)-\(key)",
                                              title: path.isEmpty ? nil : path.map(\.name).joined(separator: " › "),
                                              folders: [folder]))
                lastKey = key
            }
        }
        return sections
    }
}

#Preview {
    let model = MobileAppModel.preview()
    return NavigationStack {
        RepositoryPickerView(model: model, projectID: model.inventory!.projects[0].id)
    }
}
