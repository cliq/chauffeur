import SwiftUI

struct RecentProjectsMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Open Recent") {
            if model.recentProjects.isEmpty {
                Button("No Recent Projects") {}.disabled(true)
            } else {
                ForEach(model.recentProjects) { project in
                    Button(project.name) {
                        model.recordRecentProject(project.id)
                        openWindow(id: "project", value: project.id)
                    }
                }
            }
            Divider()
            Button("Clear Menu") { model.clearRecentProjects() }
                .disabled(model.recentProjects.isEmpty)
        }
    }
}
