import SwiftUI
import ChauffeurCore

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showArchived = false
    @State private var selectedProject: UUID?
    @State private var creatingProject = false
    @State private var createdProjectID: UUID?
    @State private var editingProject: Project?
    @State private var restored = false
    private var projects: [Project] { model.projects.filter { showArchived || !$0.archived } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 18) {
                    Image(systemName: "steeringwheel").font(.system(size: 72, weight: .light)).foregroundStyle(.tint)
                    Text("Chauffeur").font(.system(size: 32, weight: .semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")").foregroundStyle(.secondary)
                    Button("Create New Project…", systemImage: "plus") { creatingProject = true }.buttonStyle(.borderedProminent).disabled(!model.online || model.presetSets.filter { !$0.archived }.isEmpty)
                    Button("Manage Presets…") { openSettings() }
                    if model.presetSets.isEmpty { Text("Add a preset set in Settings to create your first project.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }.padding(32).frame(width: 290)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Projects").font(.headline); Spacer(); Toggle("Archived", isOn: $showArchived).toggleStyle(.checkbox).font(.caption) }.padding(.horizontal).padding(.top)
                    List(selection: $selectedProject) {
                        ForEach(projects) { project in
                            let sessions = model.sessions(in: project.id)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(project.name).fontWeight(.medium); if project.archived { Text("Archived").font(.caption).foregroundStyle(.secondary) } }
                                Text(model.setName(project.presetSetID)).font(.caption).foregroundStyle(.secondary)
                                if project.folders.filter(\.registered).count == 1, let folder = project.folders.first(where: \.registered) { Text(folder.selectedPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(folder.selectedPath) }
                                HStack(spacing: 12) {
                                    Label("\(sessions.filter { $0.state.isLive }.count) running", systemImage: "terminal")
                                    if sessions.contains(where: \.needsAttention) { Label("\(sessions.filter(\.needsAttention).count) need attention", systemImage: "bell.badge").foregroundStyle(.orange) }
                                }.font(.caption)
                            }.padding(.vertical, 6).tag(project.id).contentShape(Rectangle()).accessibilityIdentifier("project-\(project.id.uuidString)")
                                .onTapGesture(count: 2) { open(project.id) }
                                .contextMenu {
                                    Button("Open") { open(project.id) }
                                    Button("Rename…") { editingProject = project }
                                    Button(project.archived ? "Reopen Project" : "Archive Project") { let version = model.projectVersion(project.id); var changed = project; changed.archived.toggle(); model.perform { try await model.saveProject(changed, version: version) } }
                                    Button("Reveal in Finder") { if let path = model.snapshot.store.projects.first(where: { $0.value.id == project.id })?.path { FilePanels.reveal(URL(fileURLWithPath: path).deletingLastPathComponent().path) } }
                                }
                        }
                    }.onSubmit { if let selectedProject { open(selectedProject) } }
                    HStack { Spacer(); Button("Open Project") { if let selectedProject { open(selectedProject) } }.disabled(selectedProject == nil).keyboardShortcut(.defaultAction) }.padding()
                }
            }
            Divider()
            ServiceHealthView().padding(10)
        }.frame(minWidth: 780, minHeight: 460)
            .sheet(isPresented: $creatingProject, onDismiss: {
                // Closing a window while its creation sheet is still attached
                // can be ignored by macOS. Navigate after the sheet is gone.
                if let id = createdProjectID { createdProjectID = nil; open(id) }
            }) { ProjectEditor { id in createdProjectID = id; creatingProject = false } }
            .sheet(item: $editingProject) { project in ProjectEditor(project: project) { _ in editingProject = nil } }
            .sheet(item: $model.folderSelection) { selection in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose a Project").font(.title2)
                    Text("This folder belongs to more than one project.")
                    Text(selection.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    List(selection.matches) { match in
                        if let project = model.project(match.projectID) {
                            Button {
                                model.chooseProjectForFolder(match)
                                dismissWindow(id: "welcome")
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name + (project.archived ? " (Archived)" : ""))
                                    Text(model.setName(project.presetSetID)).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.frame(height: 200)
                    Button("Cancel") { model.folderSelection = nil }.keyboardShortcut(.cancelAction)
                }.padding(24).frame(width: 500)
            }
            .onChange(of: model.online) { _, online in
                guard online, !restored else { return }; restored = true
                if model.hasPendingNavigation || model.skipAutomaticWindowRestore { return }
                let windows = model.snapshot.store.windows.filter { $0.value.wasOpen && model.project($0.value.id) != nil }
                if !windows.isEmpty { for window in windows { openWindow(id: "project", value: window.value.id) }; dismissWindow(id: "welcome") }
            }
    }
    private func open(_ id: UUID) { openWindow(id: "project", value: id); dismissWindow(id: "welcome") }
}

struct ServiceHealthView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack {
            Image(systemName: model.online ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(model.online ? .green : .orange)
            Text(model.serviceMessage).font(.caption).lineLimit(2)
            let errors = model.snapshot.store.errors + model.snapshot.errors
            if !errors.isEmpty {
                Button("\(errors.count) issues…") { model.error = errors.map(\.localizedDescription).joined(separator: "\n\n") }.font(.caption)
            }
            Spacer()
            if !model.online {
                Button("Start Service") { model.registerService(); model.reconnect() }.font(.caption)
                Button("System Settings…") { model.openServiceSettings() }.font(.caption)
            }
        }
    }
}
