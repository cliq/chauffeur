import SwiftUI
import ChauffeurCore

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @State private var showArchived = false
    @State private var projectSearch = ""
    @State private var selectedProject: UUID?
    @State private var createdProjectID: UUID?
    @State private var editingProject: Project?
    @State private var restored = false
    @State private var showingSetup = false
    @State private var resumeSetup = false
    private var projects: [Project] {
        let query = projectSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.projects.filter {
            (showArchived || !$0.archived) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 18) {
                    Image("ChauffeurHat")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 92, height: 76)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Chauffeur").font(.system(size: 32, weight: .semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") · \(AppBuild.current.rawValue)").foregroundStyle(.secondary)
                    Button("Create New Project…", systemImage: "plus") { model.projectCreation = AppModel.ProjectCreation() }.buttonStyle(.borderedProminent).disabled(!model.online || model.presetSets.filter { !$0.archived }.isEmpty)
                    Button("Manage Agent Presets…") { openSettings() }
                    Button(resumeSetup ? "Resume Setup…" : "Set Up Teams…") { showingSetup = true }
                        .disabled(!model.online).accessibilityIdentifier("onboarding.open")
                    if model.presetSets.isEmpty { Text("Set up a team to choose which accounts your projects use.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                }.padding(32).frame(width: 290)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Projects").font(.headline); Spacer(); Toggle("Archived", isOn: $showArchived).toggleStyle(.checkbox).font(.caption) }.padding(.horizontal).padding(.top)
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search projects", text: $projectSearch)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("projects.search")
                            .onKeyPress(.downArrow) { moveProjectSelection(1); return .handled }
                            .onKeyPress(.upArrow) { moveProjectSelection(-1); return .handled }
                            .onSubmit { if let selectedProject { open(selectedProject) } }
                        if !projectSearch.isEmpty {
                            Button { projectSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Clear project search")
                        }
                    }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6)).padding(.horizontal)
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
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).tag(project.id).contentShape(Rectangle()).accessibilityIdentifier("project-\(project.id.uuidString)")
                        }
                    }
                    .overlay {
                        if projects.isEmpty, !projectSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No matching projects").foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                    }
                    .onChange(of: projects.map(\.id)) { _, ids in
                        if let selectedProject, !ids.contains(selectedProject) { self.selectedProject = nil }
                    }
                    // Native list activation keeps selection immediate while supporting double-click to open.
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let id = ids.first, let project = projects.first(where: { $0.id == id }) {
                            Button("Open") { open(project.id) }
                            Button("Rename…") { editingProject = project }
                            Button(project.archived ? "Reopen Project" : "Archive Project") { let version = model.projectVersion(project.id); var changed = project; changed.archived.toggle(); model.perform { try await model.saveProject(changed, version: version) } }
                            Button("Reveal in Finder") { if let path = model.snapshot.store.projects.first(where: { $0.value.id == project.id })?.path { FilePanels.reveal(URL(fileURLWithPath: path).deletingLastPathComponent().path) } }
                        }
                    } primaryAction: { ids in
                        if let id = ids.first { open(id) }
                    }
                    .onSubmit { if let selectedProject { open(selectedProject) } }
                    HStack { Spacer(); Button("Open Project") { if let selectedProject { open(selectedProject) } }.disabled(selectedProject == nil).keyboardShortcut(.defaultAction) }.padding()
                }
            }
            Divider()
            ServiceHealthView().padding(10)
        }.frame(minWidth: 780, minHeight: 460)
            .sheet(isPresented: $showingSetup, onDismiss: {
                Task { await inspectSetup(autoPresent: false) }
            }) { OnboardingWizard { _ in showingSetup = false } }
            .sheet(item: $model.projectCreation, onDismiss: {
                // Closing a window while its creation sheet is still attached
                // can be ignored by macOS. Navigate after the sheet is gone.
                if let id = createdProjectID { createdProjectID = nil; open(id) }
            }) { creation in
                ProjectEditor(initialFolderPath: creation.folderPath, initialTeamID: creation.teamID) { id in
                    createdProjectID = id
                    model.projectCreation = nil
                }.id(creation.id)
            }
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
                Task { await inspectSetup(autoPresent: true) }
                if model.hasPendingNavigation || model.skipAutomaticWindowRestore { return }
                let windows = model.snapshot.store.windows.filter { $0.value.wasOpen && model.project($0.value.id) != nil }
                if !windows.isEmpty { for window in windows { openWindow(id: "project", value: window.value.id) }; dismissWindow(id: "welcome") }
            }
            .task { if model.online { await inspectSetup(autoPresent: true) } }
    }
    private func inspectSetup(autoPresent: Bool) async {
        guard let result = try? await model.call("setupDraft"), let stored = try? result.decode(Optional<Stored<SetupDraft>>.self) else {
            if autoPresent, model.online, model.presetSets.isEmpty, model.projects.isEmpty, !model.hasPendingNavigation { showingSetup = true }
            return
        }
        resumeSetup = !stored.value.completed
        if autoPresent, model.presetSets.isEmpty, model.projects.isEmpty, !stored.value.dismissed, !stored.value.completed, !model.hasPendingNavigation { showingSetup = true }
    }
    private func moveProjectSelection(_ offset: Int) {
        let ids = projects.map(\.id)
        guard !ids.isEmpty else { selectedProject = nil; return }
        if let selectedProject, let index = ids.firstIndex(of: selectedProject) {
            self.selectedProject = ids[min(max(index + offset, 0), ids.count - 1)]
        } else {
            selectedProject = ids.first
        }
    }
    private func open(_ id: UUID) {
        projectSearch = ""
        selectedProject = nil
        openWindow(id: "project", value: id)
        dismissWindow(id: "welcome")
    }
}

struct ServiceHealthView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack {
            Image(systemName: model.online ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(model.online ? .green : .orange)
            Text(model.serviceMessage).font(.caption).lineLimit(2)
            Spacer()
            if !model.online {
                Button("Start Service") { model.registerService(forceRestart: true); model.reconnect() }.font(.caption).disabled(model.isStoppingService || model.isRestartingService)
                Button("System Settings…") { model.openServiceSettings() }.font(.caption)
            }
        }
    }
}
