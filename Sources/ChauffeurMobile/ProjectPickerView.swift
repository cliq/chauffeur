import SwiftUI
import ChauffeurRemoteProtocol

/// New session, first step: recent checkouts for a one-tap launch, then the projects. The
/// search finds projects, repositories, and branches together.
struct ProjectPickerView: View {
    var model: MobileAppModel
    @State private var query = ""

    private var projects: [ProjectSummary] {
        model.inventory?.projects.filter { !$0.archived } ?? []
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                let recents = model.recentLocations()
                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.self) { location in
                            NavigationLink(value: MobileRoute.launch(location)) {
                                LocationSummary(model: model, location: location)
                            }
                            .accessibilityIdentifier("new-session-recent")
                        }
                    }
                }
                Section("Projects") {
                    ForEach(projects) { project in
                        NavigationLink(value: model.newSessionRoute(projectID: project.id)) {
                            ProjectRow(model: model, project: project)
                        }
                        .accessibilityIdentifier("new-session-project")
                    }
                }
            } else {
                LaunchSearchSections(model: model, search: LaunchSearch(query: query, projects: projects), query: query)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Projects, repositories, branches")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .overlay {
            if projects.isEmpty {
                ContentUnavailableView("No projects", systemImage: "folder", description: Text("Add a project on your Mac to launch sessions."))
            }
        }
        .navigationTitle("New session")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Search results, grouped by what they open: a project's repositories, a repository's
/// checkouts, or Launch in a checkout.
struct LaunchSearchSections: View {
    var model: MobileAppModel
    let search: LaunchSearch
    let query: String
    /// Repeats each result's project, for searches spanning more than one.
    var showsProject = true

    var body: some View {
        if search.isEmpty {
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        }
        if !search.projects.isEmpty {
            Section("Projects") {
                ForEach(search.projects) { project in
                    NavigationLink(value: model.newSessionRoute(projectID: project.id)) {
                        ProjectRow(model: model, project: project)
                    }
                }
            }
        }
        if !search.repositories.isEmpty {
            Section("Repositories") {
                ForEach(search.repositories) { result in
                    NavigationLink(value: model.newSessionRoute(projectID: result.project.id, folderID: result.folder.id)) {
                        RepositoryRow(model: model, folder: result.folder, subtitle: showsProject ? result.project.name : nil)
                    }
                    .disabled(result.folder.availability != .available)
                }
            }
        }
        if !search.checkouts.isEmpty {
            Section("Checkouts") {
                ForEach(search.checkouts) { result in
                    NavigationLink(value: MobileRoute.launch(result.location)) {
                        LocationSummary(model: model, location: result.location)
                    }
                    .accessibilityIdentifier("new-session-search-checkout")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProjectPickerView(model: .preview())
    }
}
