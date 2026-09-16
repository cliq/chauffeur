import SwiftUI
import AppKit
import Combine
import ChauffeurCore

@MainActor final class ProjectLayout: ObservableObject {
    @Published var state: WindowState
    @Published var search = ""
    @Published var detailsVisible = false
    var controllers: [UUID: TerminalController] = [:]
    weak var window: NSWindow?
    var loaded = false
    init(projectID: UUID) { state = WindowState(projectID: projectID) }
    var selectedFolderID: UUID? { state.selectedFolderID }
    var selectedWorktreePath: String? { state.selectedWorktreePath }
    func controller(for id: UUID, scrollback: Int) -> TerminalController {
        if let controller = controllers[id] { return controller }
        let controller = TerminalController(sessionID: id, scrollback: scrollback); controllers[id] = controller; return controller
    }
    /// Selects a checkout. A `nil` path shows the repository overview. The
    /// current session stays selected when it already runs in that checkout;
    /// otherwise the first live session there is shown.
    func selectCheckout(folderID: UUID, path: String?, sessions: [Session]) {
        state.selectedFolderID = folderID
        state.selectedWorktreePath = path
        if let current = state.selectedSessionID, sessions.contains(where: { $0.id == current }) { return }
        state.selectedSessionID = path == nil ? nil : sessions.first(where: \.state.isLive)?.id
    }
    func selectSession(_ id: UUID, folderID: UUID?, path: String?) {
        state.selectedFolderID = folderID
        state.selectedWorktreePath = path
        state.selectedSessionID = id
    }
    func synchronizeTerminals(model: AppModel) {
        let visible = state.selectedSessionID.flatMap { model.session($0)?.state.isLive == true ? $0 : nil }
        for (id, controller) in controllers where id != visible { controller.detach() }
        if let visible { controller(for: visible, scrollback: model.snapshot.settings.scrollbackLines).attach(socketPath: model.socketPath) }
    }
}

struct ProjectWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var layout: ProjectLayout
    let projectID: UUID
    private struct LaunchSheet: Identifiable {
        let id = UUID()
        let folderID: UUID?
        let worktreeID: UUID?
        let newWorktree: Bool
    }
    @State private var launchSheet: LaunchSheet?
    @State private var editingProject = false
    @State private var editingGroups = false
    private struct WorktreeSheet: Identifiable {
        let id = UUID()
        let folderID: UUID?
    }
    @State private var worktreeSheet: WorktreeSheet?
    @State private var collapsedRepositories = Set<UUID>()
    private enum SidebarRowID: Hashable {
        case repository(UUID)
        case worktree(UUID, String)
    }
    private struct SidebarReveal: Identifiable {
        let id = UUID()
        let row: SidebarRowID
    }
    @State private var sidebarReveal: SidebarReveal?
    @State private var pendingWorktree: Worktree?
    @FocusState private var searchFocused: Bool
    init(projectID: UUID) { self.projectID = projectID; _layout = StateObject(wrappedValue: ProjectLayout(projectID: projectID)) }
    private var project: Project? { model.project(projectID) }
    private var allSessions: [Session] { model.sessions(in: projectID) }
    /// Sessions-mode list, narrowed by the group picker and search field.
    private var sessions: [Session] {
        allSessions.filter { (layout.state.selectedGroupID == nil || $0.groupID == layout.state.selectedGroupID) && (layout.search.isEmpty || $0.title.localizedCaseInsensitiveContains(layout.search) || $0.launch.workingDirectory.localizedCaseInsensitiveContains(layout.search)) }
    }
    private var worktreeRecords: [Worktree] { model.snapshot.store.worktrees.map(\.value) }
    private var selectedFolder: ProjectFolder? { project?.folders.first { $0.id == layout.state.selectedFolderID && $0.registered } }
    var body: some View {
        Group {
            if let project {
                NavigationSplitView(columnVisibility: Binding(get: { layout.state.sidebarVisible ? .all : .detailOnly }, set: { layout.state.sidebarVisible = $0 != .detailOnly })) {
                    sidebar(project)
                } detail: {
                    VStack(spacing: 0) {
                        if !model.online { ServiceHealthView().padding(10).background(.orange.opacity(0.12)); Divider() }
                        header(project)
                        Divider()
                        HSplitView {
                            detailArea(project)
                            if layout.detailsVisible, let session = model.session(layout.state.selectedSessionID) { SessionDetailsView(session: session, project: project).frame(minWidth: 300, idealWidth: 340, maxWidth: 460) }
                        }
                    }
                }
                .navigationTitle(project.name)
                .toolbar {
                    ToolbarItemGroup {
                        Button { showLaunch() } label: { Label("New Session", systemImage: "plus") }.disabled(!model.online || project.archived)
                        Button { layout.detailsVisible.toggle() } label: { Label("Session Details", systemImage: "sidebar.right") }.disabled(model.session(layout.state.selectedSessionID) == nil)
                        Menu {
                            Button("Project Settings…") { editingProject = true }
                            Button("Manage Groups…") { editingGroups = true }
                            Button("Manage Worktrees…") { showWorktrees(folderID: layout.selectedFolderID) }
                            Button("Open Another Project…") { openWindow(id: "welcome") }
                        } label: { Label("Project Actions", systemImage: "ellipsis.circle") }
                    }
                }
                .sheet(item: $launchSheet) { sheet in SessionLaunchView(project: project, initialGroupID: layout.state.selectedGroupID, initialFolderID: sheet.folderID, initialWorktreeID: sheet.worktreeID, startsInNewWorktree: sheet.newWorktree, worktreeCreated: revealCreatedWorktree) { selectSession($0) } }
                .sheet(isPresented: $editingProject) { ProjectEditor(project: project) { _ in editingProject = false } }
                .sheet(isPresented: $editingGroups) { GroupsEditor(project: project) }
                .sheet(item: $worktreeSheet) { selection in WorktreesView(project: project, initialFolderID: selection.folderID, worktreeCreated: revealCreatedWorktree) }
            } else {
                VStack(spacing: 20) {
                    ContentUnavailableView(model.online ? "Project unavailable" : "Connecting…", systemImage: "folder.badge.questionmark", description: Text("Restore the project directory or choose another project. Existing agents remain in the background service."))
                    ServiceHealthView(); Button("Open Projects") { openWindow(id: "welcome") }
                }.padding(24)
            }
        }.frame(minWidth: 880, minHeight: 560)
            .background(WindowObserver(projectID: projectID, layout: layout, didChangeFrame: saveLayout, didShow: {
                // Wait for the native project window to be visible before
                // closing Welcome. Preserve any other project-creation draft.
                guard project != nil else { return }
                NSApp.windows.first { $0.identifier?.rawValue == "welcome" && $0.attachedSheet == nil }?.performClose(nil)
            }, didClose: {
                for controller in layout.controllers.values { controller.detach() }
                guard !model.isTerminating else { return }
                layout.state.wasOpen = false; model.saveWindow(layout.state); model.openProjects.remove(projectID)
                layout.loaded = false
            }))
            .onAppear { restore(); consumeSessionRoute(); consumeProjectRoute() }
            .onChange(of: model.pendingSessionRoute) { _, _ in consumeSessionRoute() }
            .onChange(of: model.pendingProjectRoute) { _, _ in consumeProjectRoute() }
            .onChange(of: model.online) { _, online in if online { restore(); layout.synchronizeTerminals(model: model) } }
            .onChange(of: layout.state) { _, _ in
                guard layout.loaded else { return }
                saveLayout(); layout.synchronizeTerminals(model: model)
            }
            .onChange(of: model.snapshot.store.worktrees.map(\.value.id)) { _, ids in
                if let pendingWorktree, ids.contains(pendingWorktree.id) { self.pendingWorktree = nil }
            }
            .onChange(of: model.snapshot.sessions) { _, _ in if layout.loaded { layout.synchronizeTerminals(model: model) } }
            .onReceive(NotificationCenter.default.publisher(for: .chauffeurCommand)) { notification in
                guard layout.window?.isKeyWindow == true, let command = notification.object as? String else { return }
                switch command {
                case "new-session": showLaunch()
                case "search-sessions": layout.state.sidebarMode = .sessions; layout.state.sidebarVisible = true; searchFocused = true
                case "find": if let id = layout.state.selectedSessionID { layout.controllers[id]?.find() }
                case "next": cycle(1)
                case "previous": cycle(-1)
                case "attention": nextAttention()
                default: break
                }
            }
    }

    // MARK: Checkouts

    /// One selectable checkout row: the repository's main checkout or a worktree.
    private struct SidebarCheckout: Identifiable {
        let folderID: UUID
        let path: String
        let branch: String
        let availability: Availability
        let worktreeID: UUID?
        let isMain: Bool
        var id: String { path }
        /// Unregistered Git worktrees cannot host sessions until they are registered.
        var registered: Bool { isMain || worktreeID != nil }
        var title: String { branch.isEmpty ? (isMain ? "Main checkout" : "Detached HEAD") : branch }
    }
    private func inventory(for folder: ProjectFolder) -> RepositoryInventory? {
        model.snapshot.repositoryInventories?.first { $0.sourcePath == folder.canonicalPath || $0.sourcePaths?.contains(folder.canonicalPath) == true }
    }
    private func checkouts(for folder: ProjectFolder, project: Project) -> [SidebarCheckout] {
        var records = worktreeRecords.filter { $0.projectID == project.id && $0.folderID == folder.id && $0.registered }
        // Bridge the creation response until the next store snapshot arrives.
        if let pendingWorktree, pendingWorktree.folderID == folder.id,
           !records.contains(where: { $0.id == pendingWorktree.id }) { records.append(pendingWorktree) }
        let entries = inventory(for: folder)?.entries ?? []
        let main = SidebarCheckout(folderID: folder.id, path: folder.canonicalPath, branch: entries.first { $0.path == folder.canonicalPath }?.branch ?? "", availability: folder.availability, worktreeID: nil, isMain: true)
        var rows = records.map { SidebarCheckout(folderID: folder.id, path: $0.path, branch: $0.branch, availability: $0.availability, worktreeID: $0.id, isMain: false) }
        for entry in entries where !records.contains(where: { $0.path == entry.path || (entry.gitIdentity != nil && $0.gitIdentity == entry.gitIdentity) }) {
            rows.append(SidebarCheckout(folderID: folder.id, path: entry.path, branch: entry.branch, availability: entry.availability ?? .available, worktreeID: nil, isMain: false))
        }
        rows = rows.filter { $0.path != folder.canonicalPath }.sorted { $0.branch.localizedStandardCompare($1.branch) == .orderedAscending }
        return [main] + rows
    }
    private func checkout(folder: ProjectFolder, path: String, project: Project) -> SidebarCheckout {
        checkouts(for: folder, project: project).first { Paths.canonical($0.path) == Paths.canonical(path) }
            ?? SidebarCheckout(folderID: folder.id, path: path, branch: "", availability: .missing, worktreeID: nil, isMain: false)
    }
    private func sessions(in folder: ProjectFolder, path: String) -> [Session] {
        WorktreeSessions.sessions(allSessions, folder: folder, path: path, worktrees: worktreeRecords)
    }
    /// The checkout a session runs in: its worktree record path, else its working directory.
    private func checkout(of session: Session) -> (folderID: UUID?, path: String?) {
        guard let folder = project?.folders.first(where: { $0.id == session.folderID && $0.registered }) else { return (nil, nil) }
        let path = worktreeRecords.first { $0.id == session.worktreeID }?.path ?? session.launch.workingDirectory
        return (folder.id, path)
    }
    private func attentionCount(in folder: ProjectFolder) -> Int { allSessions.filter { $0.folderID == folder.id && $0.needsAttention }.count }
    private var canLaunch: Bool { model.online && project?.archived == false }
    private func canLaunch(in checkout: SidebarCheckout) -> Bool { canLaunch && checkout.registered && checkout.availability == .available }

    // MARK: Sidebar

    private func sidebar(_ project: Project) -> some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $layout.state.sidebarMode) {
                Text("Repositories").tag(SidebarMode.repositories)
                Text("Sessions").tag(SidebarMode.sessions)
            }.pickerStyle(.segmented).labelsHidden().padding(12).accessibilityIdentifier("sidebar.mode")
            switch layout.state.sidebarMode {
            case .repositories: repositoriesSidebar(project)
            case .sessions: sessionsSidebar(project)
            }
            Text("Closing a window keeps agents running.").font(.caption2).foregroundStyle(.secondary).padding(12)
        }.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 370)
    }
    private func repositoriesSidebar(_ project: Project) -> some View {
        ScrollViewReader { proxy in
            List {
                Section("Repositories") {
                    ForEach(project.folders.filter(\.registered)) { folder in
                        repositoryRow(folder, project: project)
                    }
                    Button("Add Folder…", systemImage: "folder.badge.plus") {
                        if let path = FilePanels.directory() { let version = model.projectVersion(project.id); var changed = project; changed.addFolder(ProjectFolder(path: path)); model.perform { try await model.saveProject(changed, version: version) } }
                    }.buttonStyle(.plain)
                }
            }.listStyle(.sidebar)
                .task(id: sidebarReveal?.id) {
                    guard let reveal = sidebarReveal else { return }
                    // Let the newly inserted row and expanded repository lay out.
                    await Task.yield()
                    guard !Task.isCancelled, sidebarReveal?.id == reveal.id else { return }
                    proxy.scrollTo(reveal.row, anchor: .center)
                }
        }
    }
    private func sessionsSidebar(_ project: Project) -> some View {
        VStack(spacing: 0) {
            Picker("Agent group", selection: $layout.state.selectedGroupID) {
                Text("All Groups").tag(UUID?.none)
                ForEach(project.groups.filter { !$0.archived || $0.id == layout.state.selectedGroupID }) { group in Text(group.name).tag(Optional(group.id)) }
            }.padding(.horizontal, 12).padding(.bottom, 8)
            TextField("Search sessions", text: $layout.search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 8).focused($searchFocused)
            List {
                if sessions.contains(where: \.needsAttention) {
                    Section("Needs Attention") {
                        ForEach(sessions.filter(\.needsAttention)) { session in sessionRow(session, project: project) }
                    }
                }
                Section("Sessions") {
                    if sessions.isEmpty { Text(allSessions.isEmpty ? "No sessions yet" : "No sessions match").font(.caption).foregroundStyle(.secondary) }
                    ForEach(sessions) { session in sessionRow(session, project: project) }
                }
            }.listStyle(.sidebar)
        }
    }
    @ViewBuilder private func badge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)").font(.caption2).fontWeight(.semibold).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1).background(.orange, in: Capsule())
                .accessibilityLabel("\(count) sessions need attention")
        }
    }
    private func repositoryRow(_ folder: ProjectFolder, project: Project) -> some View {
        let rows = checkouts(for: folder, project: project)
        let overviewSelected = layout.selectedFolderID == folder.id && layout.selectedWorktreePath == nil
        return DisclosureGroup(isExpanded: Binding(get: { !collapsedRepositories.contains(folder.id) }, set: { if $0 { collapsedRepositories.remove(folder.id) } else { collapsedRepositories.insert(folder.id) } })) {
            ForEach(rows) { row in checkoutRow(row, folder: folder, project: project) }
            Button("New Worktree & Session…", systemImage: "plus") { showLaunch(folderID: folder.id, newWorktree: true) }
                .buttonStyle(.plain).font(.caption).disabled(!canLaunch || folder.availability != .available)
                .accessibilityIdentifier("repository.new-worktree.\(folder.id)")
        } label: {
            Button { selectCheckout(folderID: folder.id, path: nil) } label: {
                HStack {
                    Label { Text(folder.name).foregroundStyle(overviewSelected ? Color.accentColor : Color.primary) } icon: { Image(systemName: FileManager.default.isReadableFile(atPath: folder.canonicalPath) ? "folder" : "folder.badge.questionmark") }
                    Spacer()
                    badge(attentionCount(in: folder))
                }
            }.buttonStyle(.plain).help(folder.selectedPath).accessibilityIdentifier("repository.\(folder.id)")
                .contextMenu {
                    Button("Launch Agent…") { showLaunch(folderID: folder.id) }.disabled(!canLaunch)
                    Button("Open Shell") { openShell(folderID: folder.id, path: folder.canonicalPath) }.disabled(!canLaunch || folder.availability != .available)
                    Button("New Worktree & Session…") { showLaunch(folderID: folder.id, newWorktree: true) }
                        .disabled(!canLaunch || folder.availability != .available)
                    Divider()
                    Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) }
                    Button("Relink / Edit Folder…") { editingProject = true }
                    Button("Reveal in Finder") { FilePanels.reveal(folder.selectedPath) }
                }
        }.id(SidebarRowID.repository(folder.id))
    }
    private func checkoutRow(_ row: SidebarCheckout, folder: ProjectFolder, project: Project) -> some View {
        let sessions = sessions(in: folder, path: row.path)
        let live = WorktreeSessions.live(sessions).count
        let selected = layout.selectedFolderID == folder.id && layout.selectedWorktreePath.map { Paths.canonical($0) == Paths.canonical(row.path) } == true
        return Button { selectCheckout(folderID: folder.id, path: row.path) } label: {
            Label {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).lineLimit(1)
                        Text(row.isMain ? "Main checkout" : URL(fileURLWithPath: row.path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if row.availability != .available { Text(row.availability.rawValue.capitalized).font(.caption).foregroundStyle(.orange) }
                        else if !row.registered { Text("Not registered").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer(minLength: 4)
                    if live > 0 { Text("\(live)").font(.caption2).foregroundStyle(.secondary).help("\(live) live sessions") }
                    badge(WorktreeSessions.attentionCount(sessions))
                }
            } icon: { Image(systemName: row.isMain ? "house" : "arrow.triangle.branch") }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(row.path)
            .accessibilityIdentifier(row.isMain ? "repository.main.\(folder.id)" : "repository.worktree.\(row.path)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(selected ? "Selected worktree" : "")
            .id(SidebarRowID.worktree(folder.id, row.path))
            .contextMenu {
                Button("Launch Agent…") { showLaunch(folderID: folder.id, worktreeID: row.worktreeID) }.disabled(!canLaunch(in: row))
                Button("Open Shell") { openShell(folderID: folder.id, path: row.path) }.disabled(!canLaunch(in: row))
                Divider()
                Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) }
                Button("Reveal in Finder") { FilePanels.reveal(row.path) }.disabled(row.availability != .available)
            }
    }
    private func sessionRow(_ session: Session, project: Project) -> some View {
        Button { selectSession(session.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Image(systemName: sessionIcon(session)); Text(session.title).lineLimit(1).fontWeight(session.id == layout.state.selectedSessionID ? .semibold : .regular) }
                Text("\(presetLabel(session)) · \(project.groups.first { $0.id == session.groupID }?.name ?? "Group unavailable")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(stateLabel(session)).font(.caption).foregroundStyle(session.needsAttention ? .orange : .secondary)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(session.title)\n\(session.launch.workingDirectory)\n\(session.launch.configurationPath)")
            .contextMenu {
                Button("Session Details") { selectSession(session.id); layout.detailsVisible = true }
                if session.state.isLive { Button("Stop Session…") { selectSession(session.id); layout.detailsVisible = true } }
            }
    }
    private func sessionIcon(_ session: Session) -> String {
        if !session.launch.preset.kind.isAgent { return "apple.terminal" }
        return session.parentID == nil ? "terminal" : "arrow.turn.down.right"
    }
    private func presetLabel(_ session: Session) -> String { session.launch.preset.kind.isAgent ? session.launch.preset.name : "Shell" }
    private func stateLabel(_ session: Session) -> String { session.state.label + (session.pendingMessages > 0 ? " · \(session.pendingMessages) messages" : "") }

    // MARK: Detail

    private func header(_ project: Project) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) { Text(project.name).font(.headline); Text(model.setName(project.presetSetID)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let folder = selectedFolder {
                let row = layout.selectedWorktreePath.map { checkout(folder: folder, path: $0, project: project) }
                VStack(alignment: .trailing, spacing: 3) {
                    Text(row?.path ?? folder.canonicalPath).font(.system(.caption, design: .monospaced)).lineLimit(1).help(row?.path ?? folder.canonicalPath)
                    Text(row.map(\.title) ?? "\(folder.name) · all checkouts").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Launch Agent…") { showLaunch(folderID: folder.id, worktreeID: row?.worktreeID) }
                        .disabled(row.map { !canLaunch(in: $0) } ?? !canLaunch).accessibilityIdentifier("checkout.launch")
                    Button("Open Shell") { openShell(folderID: folder.id, path: row?.path ?? folder.canonicalPath) }
                        .disabled(row.map { !canLaunch(in: $0) } ?? (!canLaunch || folder.availability != .available)).accessibilityIdentifier("checkout.shell")
                }.controlSize(.small)
            } else if let session = model.session(layout.state.selectedSessionID) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(session.launch.workingDirectory).font(.system(.caption, design: .monospaced)).lineLimit(1).help(session.launch.workingDirectory)
                    if let tree = worktreeRecords.first(where: { $0.id == session.worktreeID }) { Text(tree.branch).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(12)
    }
    @ViewBuilder private func detailArea(_ project: Project) -> some View {
        if let folder = selectedFolder {
            if let path = layout.state.selectedWorktreePath {
                let row = checkout(folder: folder, path: path, project: project)
                let sessions = sessions(in: folder, path: path)
                VStack(spacing: 0) {
                    if !sessions.isEmpty {
                        SessionStrip(sessions: sessions, project: project, selectedID: layout.state.selectedSessionID, select: { selectSession($0.id) }, details: { selectSession($0.id); layout.detailsVisible = true }, revealPath: { FilePanels.reveal($0.launch.workingDirectory) })
                        Divider()
                    }
                    if let selected = model.session(layout.state.selectedSessionID), sessions.contains(where: { $0.id == selected.id }) {
                        // Per-session identity so a new selection hosts its own
                        // terminal view instead of updating the previous one's.
                        TerminalPane(session: selected, controller: layout.controller(for: selected.id, scrollback: model.snapshot.settings.scrollbackLines)).frame(minWidth: 240).id(selected.id)
                    } else {
                        checkoutEmptyState(row, folder: folder, hasFinished: !WorktreeSessions.finished(sessions).isEmpty)
                    }
                }
            } else {
                repositoryOverview(folder, project: project)
            }
        } else if let selected = model.session(layout.state.selectedSessionID) {
            // The session's folder is no longer registered; the terminal still works.
            TerminalPane(session: selected, controller: layout.controller(for: selected.id, scrollback: model.snapshot.settings.scrollbackLines)).frame(minWidth: 240).id(selected.id)
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView("Choose a repository or worktree", systemImage: "arrow.triangle.branch", description: Text("Select a checkout in the sidebar to see its sessions, or launch an agent using this project's presets."))
                Button("New Session…") { showLaunch() }.buttonStyle(.borderedProminent).disabled(!canLaunch)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func checkoutEmptyState(_ row: SidebarCheckout, folder: ProjectFolder, hasFinished: Bool) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(hasFinished ? "No live sessions on this worktree" : "No sessions on this worktree", systemImage: "terminal",
                                   description: Text(row.registered ? "Launch an agent or open a shell in \(row.title)." : "Register this worktree in Manage Worktrees before launching sessions in it."))
            HStack(spacing: 12) {
                Button("Launch Agent…") { showLaunch(folderID: folder.id, worktreeID: row.worktreeID) }.buttonStyle(.borderedProminent).disabled(!canLaunch(in: row)).accessibilityIdentifier("checkout.empty.launch")
                Button("Open Shell") { openShell(folderID: folder.id, path: row.path) }.disabled(!canLaunch(in: row)).accessibilityIdentifier("checkout.empty.shell")
                if !row.registered { Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) } }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func repositoryOverview(_ folder: ProjectFolder, project: Project) -> some View {
        let rows = checkouts(for: folder, project: project)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.name).font(.title2)
                    Text(folder.canonicalPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) }
                Button("New Worktree & Session…") { showLaunch(folderID: folder.id, newWorktree: true) }.disabled(!canLaunch || folder.availability != .available)
            }.padding(20)
            List(rows) { row in
                let sessions = sessions(in: folder, path: row.path)
                let live = WorktreeSessions.live(sessions).count
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: row.isMain ? "house" : "arrow.triangle.branch").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).fontWeight(.medium)
                        Text(row.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        if row.availability != .available { Text(row.availability.rawValue.capitalized).font(.caption).foregroundStyle(.orange) }
                        else if !row.registered { Text("Not registered").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Text(live == 0 ? (sessions.isEmpty ? "No sessions" : "\(sessions.count) finished") : "\(live) live").font(.caption).foregroundStyle(.secondary)
                    badge(WorktreeSessions.attentionCount(sessions))
                    Button("Open") { selectCheckout(folderID: folder.id, path: row.path) }.controlSize(.small)
                }.padding(.vertical, 4)
                    .accessibilityIdentifier("overview.checkout.\(row.path)")
            }
        }
    }

    // MARK: Actions

    private func selectCheckout(folderID: UUID, path: String?) {
        guard let project, let folder = project.folders.first(where: { $0.id == folderID && $0.registered }) else { return }
        collapsedRepositories.remove(folderID)
        layout.selectCheckout(folderID: folderID, path: path, sessions: path.map { sessions(in: folder, path: $0) } ?? [])
        if let id = layout.state.selectedSessionID { markRead(id) }
    }
    private func selectSession(_ id: UUID) {
        guard let session = model.session(id), session.projectID == projectID else { return }
        let location = checkout(of: session)
        layout.selectSession(id, folderID: location.folderID, path: location.path)
        if layout.state.sidebarMode == .sessions, let group = layout.state.selectedGroupID, group != session.groupID { layout.state.selectedGroupID = nil }
        if let folderID = location.folderID {
            collapsedRepositories.remove(folderID)
            sidebarReveal = SidebarReveal(row: location.path.map { .worktree(folderID, $0) } ?? .repository(folderID))
        }
        markRead(id)
    }
    private func markRead(_ id: UUID) {
        guard model.session(id)?.unread == true else { return }
        model.perform { _ = try await model.call("markRead", .object(["sessionID": .string(id.uuidString)])) }
    }
    private func revealCreatedWorktree(_ tree: Worktree) {
        guard tree.projectID == projectID, tree.registered else { return }
        pendingWorktree = worktreeRecords.contains { $0.id == tree.id } ? nil : tree
        layout.state.sidebarMode = .repositories
        layout.state.sidebarVisible = true
        selectCheckout(folderID: tree.folderID, path: tree.path)
        sidebarReveal = SidebarReveal(row: .worktree(tree.folderID, tree.path))
    }
    private func showWorktrees(folderID: UUID?) {
        worktreeSheet = WorktreeSheet(folderID: folderID)
    }
    private func showLaunch(folderID: UUID? = nil, worktreeID: UUID? = nil, newWorktree: Bool = false) {
        var folderID = folderID, worktreeID = worktreeID
        if folderID == nil, let folder = selectedFolder {
            folderID = folder.id
            if worktreeID == nil, !newWorktree, let path = layout.selectedWorktreePath, let project {
                worktreeID = checkout(folder: folder, path: path, project: project).worktreeID
            }
        }
        launchSheet = LaunchSheet(folderID: folderID, worktreeID: worktreeID, newWorktree: newWorktree)
    }
    private func openShell(folderID: UUID, path: String) {
        guard let project, let folder = project.folders.first(where: { $0.id == folderID && $0.registered }) else { return }
        let row = checkout(folder: folder, path: path, project: project)
        guard canLaunch(in: row) else { return }
        model.perform {
            let session = try await model.launchShell(project: project, folder: folder, worktreeID: row.worktreeID, branch: row.branch)
            layout.selectSession(session.id, folderID: folder.id, path: row.path)
            collapsedRepositories.remove(folder.id)
        }
    }
    private func cycle(_ offset: Int) {
        let ordered: [Session]
        if let folder = selectedFolder, let path = layout.selectedWorktreePath { ordered = sessions(in: folder, path: path) }
        else { ordered = allSessions }
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == layout.state.selectedSessionID } ?? -offset.signum()
        selectSession(ordered[((current + offset) % ordered.count + ordered.count) % ordered.count].id)
    }
    private func nextAttention() {
        let attention = (layout.state.sidebarMode == .sessions ? sessions : allSessions).filter(\.needsAttention)
        guard !attention.isEmpty else { return }
        let next = attention.firstIndex { $0.id == layout.state.selectedSessionID }.map { ($0 + 1) % attention.count } ?? 0
        selectSession(attention[next].id)
    }

    // MARK: Lifecycle

    private func restore() {
        guard model.online, !layout.loaded, let project else { return }
        layout.loaded = true
        #if DEBUG
        NativeProbe.layouts[projectID] = layout
        NativeProbe.openProject = { id in openWindow(id: "project", value: id) }
        if QuickSessionProbe.enabled {
            QuickSessionProbe.openSheet[projectID] = { folderID in showLaunch(folderID: folderID, newWorktree: true) }
            QuickSessionProbe.openWorktrees[projectID] = { folderID in showWorktrees(folderID: folderID) }
        }
        #endif
        if let saved = model.snapshot.store.windows.first(where: { $0.value.id == projectID })?.value { layout.state = saved }
        model.beginWindowEditing(projectID)
        // Tabs and split panes are gone; a legacy record keeps its selected session.
        layout.state.tabs = []; layout.state.splitSessionID = nil
        if let id = layout.state.selectedSessionID, model.session(id)?.projectID != projectID { layout.state.selectedSessionID = nil }
        if let folderID = layout.state.selectedFolderID, !project.folders.contains(where: { $0.id == folderID && $0.registered }) {
            layout.state.selectedFolderID = nil; layout.state.selectedWorktreePath = nil
        }
        if layout.state.selectedFolderID == nil, let session = model.session(layout.state.selectedSessionID) {
            let location = checkout(of: session)
            layout.state.selectedFolderID = location.folderID; layout.state.selectedWorktreePath = location.path
        }
        if let folderID = layout.state.selectedFolderID { collapsedRepositories.remove(folderID) }
        layout.state.wasOpen = true; model.projectOpened(projectID); saveLayout()
        layout.synchronizeTerminals(model: model)
        consumeSessionRoute()
        consumeProjectRoute()
    }
    private func consumeProjectRoute() {
        guard layout.loaded, model.online, let navigation = model.pendingProjectRoute,
              navigation.match.projectID == projectID else { return }
        layout.state.sidebarMode = .repositories
        layout.state.sidebarVisible = true
        // A folder route names a checkout: the matched worktree, else the main
        // checkout. Its current session stays selected when it runs there.
        if let project, let folder = project.folders.first(where: { $0.id == navigation.match.folderID && $0.registered }) {
            let requested = Paths.canonical(navigation.match.path)
            let path = checkouts(for: folder, project: project).first { Paths.canonical($0.path) == requested }?.path ?? folder.canonicalPath
            selectCheckout(folderID: folder.id, path: path)
            sidebarReveal = SidebarReveal(row: .worktree(folder.id, path))
        }
        model.pendingProjectRoute = nil
        dismissWindow(id: "welcome")
        layout.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func consumeSessionRoute() {
        guard layout.loaded, model.online, let navigation = model.pendingSessionRoute,
              navigation.route.projectID == projectID,
              let session = model.session(navigation.route.sessionID), session.projectID == projectID else { return }
        layout.search = ""
        layout.state.sidebarVisible = true
        selectSession(session.id)
        model.pendingSessionRoute = nil
        dismissWindow(id: "welcome")
        layout.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func saveLayout() { if layout.loaded { model.saveWindow(layout.state) } }
}

/// Cards for every session in the selected checkout. Live sessions come first;
/// finished ones stay behind a disclosure so history remains reachable.
private struct SessionStrip: View {
    let sessions: [Session]
    let project: Project
    let selectedID: UUID?
    let select: (Session) -> Void
    let details: (Session) -> Void
    let revealPath: (Session) -> Void
    @State private var showFinished = false
    private var live: [Session] { WorktreeSessions.live(sessions) }
    /// Failed or unread sessions stay visible; other finished ones collapse.
    private var visible: [Session] { sessions.filter { $0.state.isLive || $0.needsAttention } }
    private var finished: [Session] { WorktreeSessions.finished(sessions).filter { !$0.needsAttention } }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(visible) { card($0).opacity($0.state.isLive ? 1 : 0.85) }
                if !finished.isEmpty {
                    Button { showFinished.toggle() } label: {
                        Label("Finished (\(finished.count))", systemImage: showFinished ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                        .accessibilityIdentifier("session.strip.finished")
                    if showFinished { ForEach(finished) { card($0).opacity(0.75) } }
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.scrollIndicators(.hidden).frame(height: 70).background(.bar)
            .onAppear { revealSelectedFinished() }
            .onChange(of: selectedID) { _, _ in revealSelectedFinished() }
    }
    private func revealSelectedFinished() {
        if finished.contains(where: { $0.id == selectedID }) { showFinished = true }
    }
    private func card(_ session: Session) -> some View {
        let selected = session.id == selectedID
        let preset = session.launch.preset.kind.isAgent ? session.launch.preset.name : "Shell"
        let group = project.groups.first { $0.id == session.groupID }?.name ?? "Group unavailable"
        return Button { select(session) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).fontWeight(selected ? .semibold : .medium).lineLimit(1)
                Text("\(preset) · \(group)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(session.state.label + (session.pendingMessages > 0 ? " · \(session.pendingMessages) messages" : "")).font(.caption).foregroundStyle(session.needsAttention ? .orange : .secondary).lineLimit(1)
            }.frame(minWidth: 120, maxWidth: 220, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(session.title)\n\(session.launch.workingDirectory)")
            .accessibilityIdentifier("session.card.\(session.id.uuidString)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .contextMenu {
                Button("Session Details") { details(session) }
                if session.state.isLive { Button("Stop Session…") { details(session) } }
                Button("Reveal in Finder") { revealPath(session) }
            }
    }
}

struct WindowObserver: NSViewRepresentable {
    let projectID: UUID
    @ObservedObject var layout: ProjectLayout
    let didChangeFrame: () -> Void
    let didShow: () -> Void
    let didClose: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            self.layout.window = window
            if context.coordinator.observedWindow !== window {
                window.identifier = NSUserInterfaceItemIdentifier("project-\(self.projectID.uuidString)")
                context.coordinator.observe(window)
            }
            context.coordinator.restoreFrame(window)
        }
    }
    @MainActor final class Coordinator {
        var parent: WindowObserver
        var observers: [AnyCancellable] = []
        var appliedFrame = false
        weak var observedWindow: NSWindow?
        init(parent: WindowObserver) { self.parent = parent }
        func observe(_ window: NSWindow) {
            observers.removeAll(); observedWindow = window; appliedFrame = false
            observers.append(NotificationCenter.default.publisher(for: NSWindow.didUpdateNotification, object: window).sink { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.restoreFrame(window)
            })
            for event in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.publisher(for: event, object: window).throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true).sink { [weak self, weak window] _ in
                    guard let self, let window else { return }
                    guard self.appliedFrame else { return }
                    let frame = NSStringFromRect(window.frame)
                    guard self.parent.layout.state.frame != frame else { return }
                    self.parent.layout.state.frame = frame
                    self.parent.layout.state.displayID = window.screen?.localizedName
                    self.parent.didChangeFrame()
                })
            }
            observers.append(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window).sink { [weak self] _ in self?.parent.didClose() })
        }
        func restoreFrame(_ window: NSWindow) {
            // SwiftUI applies its default size before first showing the window.
            // Wait for both that step and the initial runtime layout snapshot.
            guard parent.layout.loaded, window.isVisible, !appliedFrame else { return }
            appliedFrame = true
            if let frame = parent.layout.state.frame {
                let saved = NSRectFromString(frame)
                if saved.width >= 880, saved.height >= 560, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) { window.setFrame(saved, display: true) }
            }
            parent.layout.state.frame = NSStringFromRect(window.frame)
            parent.layout.state.displayID = window.screen?.localizedName
            parent.didChangeFrame()
            parent.didShow()
        }
    }
}
