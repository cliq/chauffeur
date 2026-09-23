import SwiftUI
import AppKit
import Combine
import ChauffeurCore

struct PendingTerminalTab: Identifiable {
    let id = UUID()
    let folderID: UUID
    let path: String
    let title: String
}

@MainActor final class ProjectLayout: ObservableObject {
    @Published var state: WindowState
    @Published var search = ""
    @Published var detailsVisible = false
    @Published var closedSessionIDs = Set<UUID>()
    @Published var newTabPresented = false
    @Published var pendingTabs: [PendingTerminalTab] = []
    var controllers: [UUID: TerminalController] = [:]
    weak var window: NSWindow?
    var loaded = false
    /// The session whose terminal should take the keyboard after a tab change,
    /// held until its view exists so typing reaches the CLI straight away.
    private var focusRequest: UUID?
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
        if let current = state.selectedSessionID, sessions.contains(where: { $0.id == current }) { requestFocus(current); return }
        state.selectedSessionID = path == nil ? nil : WorktreeSessions.selection(in: sessions, selectedID: nil)
        requestFocus(state.selectedSessionID)
    }
    func selectSession(_ id: UUID, folderID: UUID?, path: String?) {
        state.selectedFolderID = folderID
        state.selectedWorktreePath = path
        closedSessionIDs.remove(id)
        state.selectedSessionID = id
        requestFocus(id)
    }
    /// Focuses a terminal that is already on screen, otherwise records the
    /// request for the next synchronization: a just-selected session has no
    /// view yet, and a just-launched one is not in the snapshot yet either.
    private func requestFocus(_ id: UUID?) {
        focusRequest = id
        guard let id, let controller = controllers[id], controller.terminal.window != nil else { return }
        focusRequest = nil
        controller.focus()
    }
    func synchronizeTerminals(model: AppModel) {
        let visible = state.selectedSessionID.flatMap { model.session($0)?.state.isLive == true ? $0 : nil }
        for (id, controller) in controllers where id != visible { controller.detach() }
        guard let visible else { return }
        let controller = controller(for: visible, scrollback: model.snapshot.settings.scrollbackLines)
        controller.attach(socketPath: model.socketPath)
        if focusRequest == visible { focusRequest = nil; controller.focus() }
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
    @State private var deletingCheckout: CheckoutRow?
    @State private var deletionPreview = WorktreeDeletionPreview(hasChanges: false)
    @State private var checkingDeletion = false
    private struct TabClosure {
        let session: Session
        let command: String?
    }
    @State private var closingTab: TabClosure?
    @State private var checkingTab = false
    @State private var tabError: String?
    @State private var deletingSession: Session?
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
                            if layout.detailsVisible, let session = model.session(layout.state.selectedSessionID) { SessionSidebarView(session: session, project: project).frame(minWidth: 300, idealWidth: 340, maxWidth: 460) }
                        }
                    }
                }
                .navigationTitle(project.name)
                .toolbar {
                    ToolbarItemGroup {
                        ProjectTeamControl(project: project) { editingProject = true }
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
                .sheet(item: $deletingCheckout) { row in
                    WorktreeDeletionSheet(row: row, preview: deletionPreview, confirm: { deleteWorktree(row); deletingCheckout = nil }, cancel: { deletingCheckout = nil })
                }
                .confirmationDialog("Delete \(deletingSession?.title ?? "finished session")?", isPresented: Binding(get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } }), titleVisibility: .visible) {
                    Button("Delete Finished Session", role: .destructive) { if let session = deletingSession { deleteSession(session) }; deletingSession = nil }
                    Button("Cancel", role: .cancel) { deletingSession = nil }
                } message: { Text("Permanently deletes this session and its saved terminal history.") }
                .confirmationDialog("Close \(closingTab?.session.title ?? "session")?", isPresented: Binding(get: { closingTab != nil }, set: { if !$0 { closingTab = nil } }), titleVisibility: .visible) {
                    Button("Close Tab") { if let closing = closingTab { closeTab(closing.session) }; closingTab = nil }
                    Button("Cancel", role: .cancel) { closingTab = nil }
                } message: { Text(closeMessage(closingTab)) }
            } else {
                VStack(spacing: 20) {
                    ContentUnavailableView(model.online ? "Project unavailable" : "Connecting…", systemImage: "folder.badge.questionmark", description: Text("Restore the project directory or choose another project. Existing agents remain in the background service."))
                    ServiceHealthView(); Button("Open Projects") { openWindow(id: "welcome") }
                }.padding(24)
            }
        }.frame(minWidth: 880, minHeight: 560)
            .overlay { if layout.newTabPresented { newTabPrompt } }
            .alert("Could not close tab", isPresented: Binding(get: { tabError != nil }, set: { if !$0 { tabError = nil } })) {
                Button("OK") { tabError = nil }
            } message: { Text(tabError ?? "") }
            .background(WindowObserver(projectID: projectID, layout: layout, handleKey: handleKey, didChangeFrame: saveLayout, didShow: {
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
                if layout.window?.isKeyWindow == true { model.recordSessionSelection(layout.state.selectedSessionID) }
            }
            .onChange(of: model.snapshot.store.worktrees.map(\.value.id)) { _, ids in
                if let pendingWorktree, ids.contains(pendingWorktree.id) { self.pendingWorktree = nil }
            }
            .onChange(of: model.snapshot.sessions) { previous, _ in
                if layout.loaded {
                    reconcileSelection(previousSessions: previous)
                    layout.synchronizeTerminals(model: model)
                    if layout.window?.isKeyWindow == true { model.recordSessionSelection(layout.state.selectedSessionID) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard let window = notification.object as? NSWindow, window === layout.window else { return }
                model.recordRecentProject(projectID)
                model.recordSessionSelection(layout.state.selectedSessionID)
            }
            .onReceive(NotificationCenter.default.publisher(for: .chauffeurCommand)) { notification in
                guard layout.window?.isKeyWindow == true, let command = notification.object as? String else { return }
                switch command {
                case "new-session": showLaunch()
                case "new-tab": if canLaunch { layout.newTabPresented = true }
                case "search-sessions": layout.state.sidebarMode = .sessions; layout.state.sidebarVisible = true; searchFocused = true
                case "find": if let id = layout.state.selectedSessionID { layout.controllers[id]?.find() }
                case "next": cycle(1)
                case "previous": cycle(-1)
                case "sidebar-next": navigateSidebar(1)
                case "sidebar-previous": navigateSidebar(-1)
                case "attention": nextAttention()
                default: break
                }
            }
    }

    // MARK: Checkouts

    private func inventory(for folder: ProjectFolder) -> RepositoryInventory? {
        model.snapshot.repositoryInventories?.observation(for: folder.canonicalPath)
    }
    /// Whether the folder's checkouts are known yet. A folder that has not been
    /// scanned shows as loading rather than as an empty repository; offline, a
    /// missing observation cannot resolve, so it is reported as a failure.
    private func readiness(for folder: ProjectFolder) -> InventoryReadiness {
        let readiness = InventoryReadiness.of(folderPath: folder.canonicalPath, inventories: model.snapshot.repositoryInventories)
        return readiness.isPending && !model.online ? .failed("Git inventory is unavailable while the background service is offline") : readiness
    }
    private func refreshInventory() { model.perform { _ = try await model.call("refreshWorktrees") } }
    private func checkouts(for folder: ProjectFolder, project: Project) -> [CheckoutRow] {
        CheckoutRows.rows(folder: folder, project: project, records: worktreeRecords, inventory: inventory(for: folder), sessions: allSessions, pending: pendingWorktree)
    }
    private func checkout(folder: ProjectFolder, path: String, project: Project) -> CheckoutRow {
        checkouts(for: folder, project: project).first { Paths.canonical($0.path) == Paths.canonical(path) }
            ?? CheckoutRow(folderID: folder.id, path: path, branch: "", availability: .missing, worktreeID: nil, isMain: false, managed: false, sessions: sessions(in: folder, path: path))
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
    private func attentionCount(in folder: ProjectFolder) -> Int { WorktreeSessions.attentionCount(allSessions.filter { $0.folderID == folder.id }) }
    private var canLaunch: Bool { model.online && project?.archived == false }
    private func canLaunch(in checkout: CheckoutRow) -> Bool { canLaunch && checkout.availability == .available }

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
    /// Sessions still running in a checkout. Green means working; the orange
    /// attention badge beside it means waiting on the user.
    @ViewBuilder private func liveBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)").font(.caption2).fontWeight(.semibold).foregroundStyle(.green)
                .padding(.horizontal, 6).padding(.vertical, 1).background(.green.opacity(0.18), in: Capsule())
                .help("\(count) live session\(count == 1 ? "" : "s")")
                .accessibilityLabel("\(count) live sessions")
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
        let readiness = readiness(for: folder)
        return DisclosureGroup(isExpanded: Binding(get: { !collapsedRepositories.contains(folder.id) }, set: { if $0 { collapsedRepositories.remove(folder.id) } else { collapsedRepositories.insert(folder.id) } })) {
            if readiness.isPending {
                inventoryPendingRow(folder)
            } else {
                ForEach(rows) { row in checkoutRow(row, folder: folder, project: project) }
                inventoryStatusRow(readiness, folder: folder)
            }
            Button("New Worktree & Session…", systemImage: "plus") { showLaunch(folderID: folder.id, newWorktree: true) }
                .buttonStyle(.plain).font(.caption).disabled(!canLaunch || folder.availability != .available || readiness.isPending)
                .accessibilityIdentifier("repository.new-worktree.\(folder.id)")
        } label: {
            Button { selectCheckout(folderID: folder.id, path: nil) } label: {
                HStack {
                    Label { Text(folder.name).foregroundStyle(overviewSelected ? Color.accentColor : Color.primary) } icon: { Image(systemName: FileManager.default.isReadableFile(atPath: folder.canonicalPath) ? "folder" : "folder.badge.questionmark") }
                    Spacer()
                    badge(attentionCount(in: folder))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(folder.selectedPath).accessibilityIdentifier("repository.\(folder.id)")
                .contextMenu {
                    Button("Launch Agent…") { showLaunch(folderID: folder.id) }.disabled(!canLaunch || readiness.isPending)
                    Button("Open Shell") { openShell(in: rows[0], folder: folder) }.disabled(!canLaunch(in: rows[0]) || readiness.isPending)
                    Button("New Worktree & Session…") { showLaunch(folderID: folder.id, newWorktree: true) }
                        .disabled(!canLaunch || folder.availability != .available || readiness.isPending)
                    Divider()
                    Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) }.disabled(readiness.isPending)
                    Button("Relink / Edit Folder…") { editingProject = true }
                    Button("Reveal in Finder") { FilePanels.reveal(folder.selectedPath) }
                }
        }.id(SidebarRowID.repository(folder.id))
    }
    private func inventoryPendingRow(_ folder: ProjectFolder) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading Git inventory…").font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 6).padding(.vertical, 4)
            .accessibilityElement(children: .combine).accessibilityIdentifier("repository.loading.\(folder.id)")
    }
    @ViewBuilder private func inventoryStatusRow(_ readiness: InventoryReadiness, folder: ProjectFolder) -> some View {
        switch readiness {
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button("Retry Git Inventory", systemImage: "arrow.clockwise") { refreshInventory() }
                    .buttonStyle(.plain).font(.caption).disabled(!model.online)
                    .accessibilityIdentifier("repository.retry-inventory.\(folder.id)")
            }.padding(.horizontal, 6).padding(.vertical, 4)
        case .notRepository:
            Text("Not a Git repository").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
        case .pending, .ready:
            EmptyView()
        }
    }
    private func checkoutRow(_ row: CheckoutRow, folder: ProjectFolder, project: Project) -> some View {
        let sessions = sessions(in: folder, path: row.path)
        let live = WorktreeSessions.live(sessions).count
        let selected = layout.selectedFolderID == folder.id && layout.selectedWorktreePath.map { Paths.canonical($0) == Paths.canonical(row.path) } == true
        return Button { selectCheckout(folderID: folder.id, path: row.path) } label: {
            Label {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(row.title).lineLimit(1)
                            if row.isDirty {
                                Circle().fill(.secondary).frame(width: 6, height: 6)
                                    .help("Uncommitted changes")
                                    .accessibilityLabel("Uncommitted changes")
                                    .accessibilityIdentifier("repository.dirty.\(row.path)")
                            }
                        }
                        HStack(spacing: 4) {
                            Text(row.isMain ? "Main checkout" : URL(fileURLWithPath: row.path).lastPathComponent).lineLimit(1)
                            if let unmerged = row.unmergedDescription {
                                Text("·")
                                HStack(spacing: 3) { UnmergedCommitsGlyph(); Text("\(row.unmergedCount)") }
                                    .help(unmerged).accessibilityElement(children: .combine).accessibilityLabel(unmerged)
                                    .accessibilityIdentifier("repository.unmerged.\(row.path)")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let status = row.statusLabel { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 4)
                    liveBadge(live)
                    badge(WorktreeSessions.attentionCount(sessions))
                }
            } icon: { Image(systemName: row.isMain ? "house" : "arrow.triangle.branch") }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(row.path)
            .accessibilityIdentifier(row.isMain ? "repository.main.\(folder.id)" : "repository.worktree.\(row.path)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(selected ? "Selected worktree" : "")
            .id(SidebarRowID.worktree(folder.id, row.path))
            .contextMenu { checkoutMenu(row, folder: folder) }
    }
    @ViewBuilder private func checkoutMenu(_ row: CheckoutRow, folder: ProjectFolder) -> some View {
        Button("Launch Agent…") { launchAgent(in: row, folder: folder) }.disabled(!canLaunch(in: row))
        Button("Open Shell") { openShell(in: row, folder: folder) }.disabled(!canLaunch(in: row))
        Divider()
        Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) }
        Button("Reveal in Finder") { FilePanels.reveal(row.path) }.disabled(row.availability != .available)
        if !row.isMain {
            Divider()
            Button("Delete Worktree…", role: .destructive) { prepareDeletion(row) }
                .disabled(!model.online || !row.liveSessions.isEmpty)
                .help(row.liveSessions.isEmpty ? "" : "Stop its live sessions first")
        }
    }
    private func sessionRow(_ session: Session, project: Project) -> some View {
        Button { selectSession(session.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Image(systemName: sessionIcon(session)); Text(session.title).lineLimit(1).fontWeight(session.id == layout.state.selectedSessionID ? .semibold : .regular) }
                Text("\(presetLabel(session)) · \(project.groups.first { $0.id == session.groupID }?.name ?? "Group unavailable")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let status = session.visibleStatus {
                    Text(status).font(.caption).foregroundStyle(session.needsAttention ? .orange : .secondary)
                }
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(session.title)\n\(session.launch.workingDirectory)\n\(session.launch.configurationPath)")
            .contextMenu {
                Button("Session Details") { selectSession(session.id); layout.detailsVisible = true }
                if session.state.isLive { Button("Stop Session…") { selectSession(session.id); layout.detailsVisible = true } }
                else { Button("Delete Finished Session…", role: .destructive) { deletingSession = session }.disabled(!model.online) }
            }
    }
    private func sessionIcon(_ session: Session) -> String {
        if !session.launch.preset.kind.isAgent { return "apple.terminal" }
        return session.parentID == nil ? "terminal" : "arrow.turn.down.right"
    }
    private func presetLabel(_ session: Session) -> String { session.launch.preset.kind.isAgent ? session.launch.preset.name : "Shell" }

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
                let target = row ?? checkout(folder: folder, path: folder.canonicalPath, project: project)
                HStack(spacing: 8) {
                    Button("Launch Agent…") { launchAgent(in: target, folder: folder) }
                        .disabled(!canLaunch(in: target)).accessibilityIdentifier("checkout.launch")
                    Button("Open Shell") { openShell(in: target, folder: folder) }
                        .disabled(!canLaunch(in: target)).accessibilityIdentifier("checkout.shell")
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
                let sessions = openSessions(in: folder, path: path)
                let pending = layout.pendingTabs.filter { $0.folderID == folder.id && $0.path == path }
                let selectedPending = pending.first { $0.id == layout.state.selectedSessionID }
                let selectedID = selectedPending?.id ?? WorktreeSessions.selection(in: sessions, selectedID: layout.state.selectedSessionID)
                VStack(spacing: 0) {
                    if !sessions.isEmpty || !pending.isEmpty {
                        SessionStrip(pendingTabs: pending, selectPending: { layout.state.selectedSessionID = $0 }, sessions: sessions, project: project, keepFinishedSessions: model.snapshot.settings.keepFinishedSessions, close: { requestCloseTab($0) }, move: { source, target in
                            layout.state.sessionTabOrder = WorktreeSessions.movingTab(source, to: target, displayed: sessions.map(\.id), savedOrder: layout.state.sessionTabOrder)
                        }, delete: { deletingSession = $0 }, selectedID: selectedID, select: { selectSession($0.id) }, details: { selectSession($0.id); layout.detailsVisible = true }, revealPath: { FilePanels.reveal($0.launch.workingDirectory) })
                        Divider()
                    }
                    if let selectedPending {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Starting \(selectedPending.title)…").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("terminal.launching")
                    } else if let selected = sessions.first(where: { $0.id == selectedID }) {
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
                ContentUnavailableView("Choose a repository or worktree", systemImage: "arrow.triangle.branch", description: Text("Select a checkout in the sidebar to see its sessions, or launch an agent using this project's agent presets."))
                Button("New Session…") { showLaunch() }.buttonStyle(.borderedProminent).disabled(!canLaunch)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func checkoutEmptyState(_ row: CheckoutRow, folder: ProjectFolder, hasFinished: Bool) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(row.finished ? "This worktree is finished" : (hasFinished ? "No live sessions on this worktree" : "No sessions on this worktree"), systemImage: "terminal",
                                   description: Text(row.finished ? "The checkout no longer exists. Its finished sessions stay available above until you delete the worktree." : "Launch an agent or open a shell in \(row.title)."))
            HStack(spacing: 12) {
                if row.finished {
                    Button("Delete Worktree…", role: .destructive) { prepareDeletion(row) }.disabled(!model.online || !row.liveSessions.isEmpty)
                } else {
                    Button("Launch Agent…") { launchAgent(in: row, folder: folder) }.buttonStyle(.borderedProminent).disabled(!canLaunch(in: row)).accessibilityIdentifier("checkout.empty.launch")
                    Button("Open Shell") { openShell(in: row, folder: folder) }.disabled(!canLaunch(in: row)).accessibilityIdentifier("checkout.empty.shell")
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func repositoryOverview(_ folder: ProjectFolder, project: Project) -> some View {
        let rows = checkouts(for: folder, project: project)
        let readiness = readiness(for: folder)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(folder.name).font(.title2)
                    Text(folder.canonicalPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) }.disabled(readiness.isPending)
                Button("New Worktree & Session…") { showLaunch(folderID: folder.id, newWorktree: true) }.disabled(!canLaunch || folder.availability != .available || readiness.isPending)
            }.padding(20)
            if readiness.isPending {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading Git inventory…").foregroundStyle(.secondary)
                    Text("Worktrees and branches appear when the background service finishes scanning this repository.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("overview.loading.\(folder.id)")
            } else {
            if case .failed(let message) = readiness {
                HStack {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry Git Inventory") { refreshInventory() }.disabled(!model.online)
                }.padding(.horizontal, 20).padding(.bottom, 8)
            }
            List(rows) { row in
                let sessions = sessions(in: folder, path: row.path)
                let live = WorktreeSessions.live(sessions).count
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: row.isMain ? "house" : "arrow.triangle.branch").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).fontWeight(.medium)
                        Text(row.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        if let status = row.statusLabel { Text(status).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(live == 0 ? (sessions.isEmpty ? "No sessions" : "\(sessions.count) finished") : "\(live) live").font(.caption).foregroundStyle(.secondary)
                    badge(WorktreeSessions.attentionCount(sessions))
                    Button("Open") { selectCheckout(folderID: folder.id, path: row.path) }.controlSize(.small)
                }.padding(.vertical, 4)
                    .contextMenu { checkoutMenu(row, folder: folder) }
                    .accessibilityIdentifier("overview.checkout.\(row.path)")
            }
            }
        }
    }

    // MARK: Actions

    private func openSessions(in folder: ProjectFolder, path: String) -> [Session] {
        WorktreeSessions.orderedTabs(sessions(in: folder, path: path).filter { session in
            !layout.closedSessionIDs.contains(session.id) && !layout.pendingTabs.contains { $0.id == session.id }
        }, savedOrder: layout.state.sessionTabOrder)
    }
    private func reconcileSelection(previousSessions: [Session] = []) {
        guard !layout.pendingTabs.contains(where: { $0.id == layout.state.selectedSessionID }) else { return }
        guard let folder = selectedFolder, let path = layout.selectedWorktreePath else { return }
        let previous = WorktreeSessions.sessions(previousSessions, folder: folder, path: path, worktrees: worktreeRecords)
        let next = WorktreeSessions.selection(in: openSessions(in: folder, path: path), selectedID: layout.state.selectedSessionID, previousOrder: previous.map(\.id))
        guard next != layout.state.selectedSessionID else { return }
        if let next { selectSession(next) } else { layout.state.selectedSessionID = nil }
    }
    private var openTabs: [Session] {
        if let folder = selectedFolder, let path = layout.selectedWorktreePath { return openSessions(in: folder, path: path) }
        return model.session(layout.state.selectedSessionID).map { [$0] } ?? []
    }
    /// Closing a tab stops its session, so confirm before ending work in
    /// progress. A shell waiting at its own prompt closes without asking.
    private func closeCurrentTab() {
        guard closingTab == nil, !checkingTab else { return }
        if let id = layout.state.selectedSessionID, layout.pendingTabs.contains(where: { $0.id == id }) {
            layout.pendingTabs.removeAll { $0.id == id }
            model.forgetSessionSelection(id)
            layout.closedSessionIDs.insert(id)
            layout.state.selectedSessionID = layout.pendingTabs.last(where: {
                $0.folderID == layout.selectedFolderID && $0.path == layout.selectedWorktreePath
            })?.id
            reconcileSelection()
            return
        }
        let tabs = openTabs
        guard !tabs.isEmpty else { layout.window?.performClose(nil); return }
        let closing = tabs[tabs.firstIndex { $0.id == layout.state.selectedSessionID } ?? 0]
        requestCloseTab(closing)
    }
    private func requestCloseTab(_ closing: Session) {
        guard closingTab == nil, !checkingTab, model.online else { return }
        guard closing.state.isLive else { closeTab(closing); return }
        guard !closing.launch.preset.kind.isAgent else { closingTab = TabClosure(session: closing, command: nil); return }
        checkingTab = true
        Task {
            let activity = await model.terminalActivity(closing.id)
            checkingTab = false
            if activity.idle { closeTab(closing) } else { closingTab = TabClosure(session: closing, command: activity.command) }
        }
    }
    private func closeTab(_ session: Session) {
        finishTab(session, method: "closeSession")
    }
    private func deleteSession(_ session: Session) {
        finishTab(session, method: "deleteSession")
    }
    private func finishTab(_ session: Session, method: String) {
        guard !checkingTab, model.online else { return }
        let tabs = openTabs
        let wasSelected = layout.state.selectedSessionID == session.id
        model.forgetSessionSelection(session.id)
        layout.closedSessionIDs.insert(session.id)
        layout.controllers.removeValue(forKey: session.id)?.detach()
        if wasSelected {
            let remaining = tabs.filter { $0.id != session.id }
            if let next = WorktreeSessions.selection(in: remaining, selectedID: session.id, previousOrder: tabs.map(\.id)) {
                selectSession(next)
            } else {
                layout.state.selectedSessionID = nil
            }
        }
        Task {
            do {
                _ = try await model.call(method, .object(["sessionID": .string(session.id.uuidString)]))
            } catch {
                layout.closedSessionIDs.remove(session.id)
                if wasSelected && layout.state.selectedSessionID == nil { selectSession(session.id) }
                tabError = "\(session.title): \(error.localizedDescription)"
            }
            try? await model.refresh()
            // Keep the tab closed after cleanup too. History remains available
            // through the session sidebar, which explicitly reopens it on selection.
        }
    }

    private func closeMessage(_ closing: TabClosure?) -> String {
        let running = closing?.command.map { "“\($0)” is running in this terminal." } ?? "This session is still running."
        return running + ((model.snapshot.settings.keepFinishedSessions || closing?.session.historyProtected == true)
            ? " Closing the tab stops it and keeps its history in Finished."
            : " Closing the tab stops it and permanently deletes its saved history.")
    }
    private var terminalTarget: (folder: ProjectFolder, row: CheckoutRow)? {
        guard let project, let folder = selectedFolder ?? project.folders.first(where: \.registered) else { return nil }
        return (folder, checkout(folder: folder, path: layout.selectedWorktreePath ?? folder.canonicalPath, project: project))
    }
    private func createTerminalTab() {
        guard let target = terminalTarget, canLaunch(in: target.row) else { return }
        layout.newTabPresented = false
        openShell(in: target.row, folder: target.folder)
    }
    private func createAgentTab() {
        guard canLaunch else { return }
        layout.newTabPresented = false
        showLaunch()
    }
    private var newTabPrompt: some View {
        ZStack {
            Color.black.opacity(0.2).contentShape(Rectangle()).onTapGesture { layout.newTabPresented = false }
            VStack(alignment: .leading, spacing: 16) {
                Text("New Tab").font(.headline)
                Button(action: createTerminalTab) {
                    HStack { Label("Terminal", systemImage: "terminal"); Spacer(); Text("T").foregroundStyle(.secondary) }
                }.disabled(terminalTarget.map { !canLaunch(in: $0.row) } ?? true)
                    .accessibilityIdentifier("new-tab.terminal")
                Button(action: createAgentTab) {
                    HStack { Label("Agent…", systemImage: "sparkles"); Spacer(); Text("A").foregroundStyle(.secondary) }
                }.disabled(!canLaunch).accessibilityIdentifier("new-tab.agent")
                Button("Cancel") { layout.newTabPresented = false }.font(.caption)
            }.buttonStyle(.plain).padding(20).frame(width: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).shadow(radius: 20)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("new-tab.prompt")
        }
    }
    /// Handle the chord before SwiftTerm or the native Close Window shortcut.
    /// The prompt state changes synchronously so a fast second key is not lost.
    private func handleKey(_ event: NSEvent) -> Bool {
        if let terminal = event.window?.firstResponder as? ThemedTerminalView, terminal.sendWordNavigation(event) { return true }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if layout.newTabPresented {
            if event.keyCode == 53 || (modifiers == .command && key == "w") {
                layout.newTabPresented = false
            } else if !event.isARepeat && (modifiers.isEmpty || modifiers == .command) {
                if key == "t" { createTerminalTab() }
                if key == "a" { createAgentTab() }
            }
            // Keep prompt keystrokes out of the underlying terminal; allow Quit.
            return !(modifiers == .command && key == "q")
        }
        if event.keyCode == 48 && (modifiers == .control || modifiers == [.control, .shift]) {
            cycle(modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        if modifiers == [.control, .command], event.keyCode == 123 || event.keyCode == 124 {
            model.navigateSessionHistory(event.keyCode == 123 ? -1 : 1)
            return true
        }
        guard modifiers == .command else { return false }
        if key == "w" {
            if !event.isARepeat { closeCurrentTab() }
            return true
        }
        if key == "t" {
            if !event.isARepeat && canLaunch { layout.newTabPresented = true }
            return true
        }
        return false
    }

    private func selectCheckout(folderID: UUID, path: String?) {
        guard let project, let folder = project.folders.first(where: { $0.id == folderID && $0.registered }) else { return }
        collapsedRepositories.remove(folderID)
        layout.selectCheckout(folderID: folderID, path: path, sessions: path.map { openSessions(in: folder, path: $0) } ?? [])
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
        if folderID == nil, !newWorktree, let folder = selectedFolder, let project {
            // The selected checkout may be a Git worktree Chauffeur has not recorded yet.
            launchAgent(in: checkout(folder: folder, path: layout.selectedWorktreePath ?? folder.canonicalPath, project: project), folder: folder)
            return
        }
        launchSheet = LaunchSheet(folderID: folderID ?? selectedFolder?.id, worktreeID: worktreeID, newWorktree: newWorktree)
    }
    /// Opens the launch sheet for a checkout, recording the worktree first if needed.
    private func launchAgent(in row: CheckoutRow, folder: ProjectFolder) {
        guard let project, canLaunch(in: row) else { return }
        model.perform {
            let worktreeID = try await model.worktreeID(for: row, project: project)
            launchSheet = LaunchSheet(folderID: folder.id, worktreeID: worktreeID, newWorktree: false)
        }
    }
    private func openShell(in row: CheckoutRow, folder: ProjectFolder) {
        guard let project, canLaunch(in: row) else { return }
        let pending = PendingTerminalTab(folderID: folder.id, path: row.path, title: "Shell · \(row.branch.isEmpty ? folder.name : row.branch)")
        layout.pendingTabs.append(pending)
        layout.selectSession(pending.id, folderID: folder.id, path: row.path)
        collapsedRepositories.remove(folder.id)
        model.perform {
            do {
                let worktreeID = try await model.worktreeID(for: row, project: project)
                let session = try await model.launchShell(project: project, folder: folder, worktreeID: worktreeID, branch: row.branch, sessionID: pending.id)
                // A loading tab can be closed before launch returns.
                guard layout.pendingTabs.contains(where: { $0.id == pending.id }) else {
                    layout.closedSessionIDs.insert(session.id)
                    do {
                        _ = try await model.call("closeSession", .object(["sessionID": .string(session.id.uuidString)]))
                    } catch {
                        layout.closedSessionIDs.remove(session.id)
                        throw error
                    }
                    return
                }
                let stillSelected = layout.state.selectedSessionID == pending.id
                layout.pendingTabs.removeAll { $0.id == pending.id }
                if stillSelected { layout.selectSession(session.id, folderID: folder.id, path: row.path) }
            } catch {
                layout.pendingTabs.removeAll { $0.id == pending.id }
                if layout.state.selectedSessionID == pending.id {
                    layout.state.selectedSessionID = nil
                    reconcileSelection()
                }
                throw error
            }
        }
    }

    private func prepareDeletion(_ row: CheckoutRow) {
        guard let project, !checkingDeletion else { return }
        checkingDeletion = true
        model.perform {
            defer { checkingDeletion = false }
            let preview = try await model.call("previewWorktreeDeletion", .object(["projectID": .string(project.id.uuidString), "folderID": .string(row.folderID.uuidString), "path": .string(row.path)]))
            deletionPreview = try preview.decode(WorktreeDeletionPreview.self)
            deletingCheckout = row
        }
    }
    private func deleteWorktree(_ row: CheckoutRow) {
        guard let project else { return }
        let discardChanges = deletionPreview.hasChanges
        model.perform {
            _ = try await model.call("deleteWorktree", .object(["projectID": .string(project.id.uuidString), "folderID": .string(row.folderID.uuidString), "path": .string(row.path), "discardChanges": .bool(discardChanges)]))
            if layout.selectedWorktreePath.map({ Paths.canonical($0) == Paths.canonical(row.path) }) == true {
                layout.selectCheckout(folderID: row.folderID, path: nil, sessions: [])
            }
        }
    }
    private func cycle(_ offset: Int) {
        let ordered: [Session]
        if let folder = selectedFolder, let path = layout.selectedWorktreePath { ordered = openSessions(in: folder, path: path) }
        else { ordered = allSessions.filter { !layout.closedSessionIDs.contains($0.id) } }
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.id == layout.state.selectedSessionID } ?? -offset.signum()
        selectSession(ordered[((current + offset) % ordered.count + ordered.count) % ordered.count].id)
    }
    /// The sidebar rows ⌘↑/⌘↓ moves through in Repositories mode: every
    /// registered repository followed by its checkouts, collapsed ones aside.
    private func sidebarRows(_ project: Project) -> [(folderID: UUID, path: String?)] {
        project.folders.filter(\.registered).flatMap { folder -> [(folderID: UUID, path: String?)] in
            let repository = [(folderID: folder.id, path: String?.none)]
            guard !collapsedRepositories.contains(folder.id) else { return repository }
            return repository + checkouts(for: folder, project: project).map { (folderID: folder.id, path: String?($0.path)) }
        }
    }
    /// Moves the sidebar selection without leaving the terminal: the selected
    /// checkout or session changes and its terminal takes the keyboard.
    private func navigateSidebar(_ offset: Int) {
        guard let project else { return }
        layout.state.sidebarVisible = true
        if layout.state.sidebarMode == .sessions {
            let ordered = sessions
            guard !ordered.isEmpty else { return }
            let current = ordered.firstIndex { $0.id == layout.state.selectedSessionID } ?? -offset.signum()
            selectSession(ordered[((current + offset) % ordered.count + ordered.count) % ordered.count].id)
            return
        }
        let rows = sidebarRows(project)
        guard !rows.isEmpty else { return }
        let selected = layout.selectedWorktreePath.map { Paths.canonical($0) }
        let current = rows.firstIndex { $0.folderID == layout.selectedFolderID && $0.path.map { Paths.canonical($0) } == selected } ?? -offset.signum()
        let row = rows[((current + offset) % rows.count + rows.count) % rows.count]
        selectCheckout(folderID: row.folderID, path: row.path)
        sidebarReveal = SidebarReveal(row: row.path.map { .worktree(row.folderID, $0) } ?? .repository(row.folderID))
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
        reconcileSelection()
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
        model.recordSessionSelection(session.id)
    }
    private func saveLayout() { if layout.loaded { model.saveWindow(layout.state) } }
}

/// Cards for every session in the selected checkout. Live sessions come first;
/// finished ones stay behind a disclosure so history remains reachable.
private struct SessionStrip: View {
    var pendingTabs: [PendingTerminalTab] = []
    var selectPending: (UUID) -> Void = { _ in }
    let sessions: [Session]
    let project: Project
    let keepFinishedSessions: Bool
    let close: (Session) -> Void
    let move: (UUID, UUID) -> Void
    let delete: (Session) -> Void
    let selectedID: UUID?
    let select: (Session) -> Void
    let details: (Session) -> Void
    let revealPath: (Session) -> Void
    @State private var showFinished = false
    @State private var hoveredCloseID: UUID?
    @State private var hoveredID: UUID?
    @State private var dropTargetID: UUID?
    private var live: [Session] { WorktreeSessions.live(sessions) }
    /// Failed or unread sessions stay visible; other finished ones collapse.
    private var visible: [Session] { sessions.filter { !keepFinishedSessions || $0.state.isLive || $0.needsAttention } }
    private var finished: [Session] { keepFinishedSessions ? WorktreeSessions.finished(sessions).filter { !$0.needsAttention } : [] }
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(visible) { card($0).id($0.id).opacity($0.state.isLive ? 1 : 0.85) }
                        ForEach(pendingTabs) { tab in
                            Button { selectPending(tab.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tab.title).fontWeight(.medium).lineLimit(1)
                                    HStack { ProgressView().controlSize(.small).accessibilityHidden(true); Text("Starting…").font(.caption).foregroundStyle(.secondary) }
                                }.frame(minWidth: 120, maxWidth: 220, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(tab.id == selectedID ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                                .id(tab.id)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(tab.title), Starting")
                                .accessibilityAddTraits(.isButton)
                                .accessibilityIdentifier("session.pending.\(tab.id.uuidString)")
                                .accessibilityAddTraits(tab.id == selectedID ? .isSelected : [])
                        }
                        if !finished.isEmpty {
                            Button { showFinished.toggle() } label: {
                                Label("Finished (\(finished.count))", systemImage: showFinished ? "chevron.down" : "chevron.right")
                            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                                .accessibilityIdentifier("session.strip.finished")
                            if showFinished { ForEach(finished) { card($0).id($0.id).opacity(0.75) } }
                        }
                    }.padding(.horizontal, 10).padding(.vertical, 6)
                }.scrollIndicators(.hidden)
                    .onAppear { revealSelectedFinished(); if let selectedID { proxy.scrollTo(selectedID) } }
                    .onChange(of: selectedID) { _, _ in revealSelectedFinished(); if let selectedID { proxy.scrollTo(selectedID) } }
            }
            Button {
                WorktreeSessions.finished(sessions).forEach(close)
            } label: {
                Image(systemName: "xmark.square.stack")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .disabled(WorktreeSessions.finished(sessions).isEmpty)
            .help("Close all finished tabs")
            .accessibilityLabel("Close all finished tabs")
            .accessibilityIdentifier("session.strip.closeFinished")
            .padding(.horizontal, 8)
        }.frame(height: 70).background(.bar)
    }
    private func cardHelp(_ session: Session) -> String {
        var lines = [session.title, session.launch.workingDirectory]
        if session.coordinationEnabled { lines.append("Chauffeur coordination on") }
        if let warning = session.conversationWarning { lines.append(warning) }
        if let warning = session.executableWarning { lines.append(warning) }
        return lines.joined(separator: "\n")
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
                HStack(spacing: 4) {
                    if session.coordinationEnabled {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .accessibilityLabel("Coordination on")
                            .accessibilityIdentifier("session.coordination.\(session.id.uuidString)")
                    }
                    if session.conversationWarning != nil || session.executableWarning != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityLabel(session.executableWarning != nil ? "Agent was updated while running" : "Conversation also open in another session")
                    }
                    Text("\(preset) · \(group)").lineLimit(1)
                }.font(.caption).foregroundStyle(.secondary)
                if let status = session.visibleStatus {
                    Text(status).font(.caption).foregroundStyle(session.needsAttention ? .orange : .secondary).lineLimit(1)
                }
            }.frame(minWidth: 120, maxWidth: 220, alignment: .leading)
                .padding(.leading, 10).padding(.trailing, 30).padding(.vertical, 6)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(cardHelp(session))
            .accessibilityIdentifier("session.card.\(session.id.uuidString)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .draggable("chauffeur-tab:\(project.id):\(session.id)")
            .overlay(alignment: .trailing) {
                Button { close(session) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(hoveredCloseID == session.id ? Color.primary.opacity(0.14) : Color.clear, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).padding(.trailing, 4)
                .onHover { hovering in
                    if hovering { hoveredCloseID = session.id }
                    else if hoveredCloseID == session.id { hoveredCloseID = nil }
                }
                .opacity(hoveredID == session.id ? 1 : 0)
                .allowsHitTesting(hoveredID == session.id)
                .accessibilityHidden(hoveredID != session.id)
                .accessibilityLabel("Close \(session.title)")
                .accessibilityIdentifier("session.close.\(session.id.uuidString)")
                .help("Close tab")
            }
            .onHover { hovering in
                if hovering { hoveredID = session.id }
                else if hoveredID == session.id { hoveredID = nil; hoveredCloseID = nil }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let item = items.first,
                      item.hasPrefix("chauffeur-tab:\(project.id):"),
                      let source = UUID(uuidString: String(item.dropFirst("chauffeur-tab:\(project.id):".count))),
                      sessions.contains(where: { $0.id == source }), source != session.id else { return false }
                move(source, session.id)
                return true
            } isTargeted: { targeted in
                if targeted { dropTargetID = session.id }
                else if dropTargetID == session.id { dropTargetID = nil }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6).stroke(dropTargetID == session.id ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .contextMenu {
                Button("Session Details") { details(session) }
                if session.state.isLive { Button("Stop Session…") { details(session) } }
                else { Button("Delete Finished Session…", role: .destructive) { delete(session) } }
                Button("Reveal in Finder") { revealPath(session) }
            }
    }
}

struct WindowObserver: NSViewRepresentable {
    let projectID: UUID
    @ObservedObject var layout: ProjectLayout
    let handleKey: (NSEvent) -> Bool
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
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoringKeys()
    }
    @MainActor final class Coordinator {
        var parent: WindowObserver
        var keyMonitor: Any?
        func stopMonitoringKeys() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        var observers: [AnyCancellable] = []
        var appliedFrame = false
        weak var observedWindow: NSWindow?
        init(parent: WindowObserver) { self.parent = parent }
        func observe(_ window: NSWindow) {
            observers.removeAll(); observedWindow = window; appliedFrame = false
            stopMonitoringKeys()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
                guard let self, let window, window.isKeyWindow, event.window === window,
                      window.attachedSheet == nil else { return event }
                return self.parent.handleKey(event) ? nil : event
            }
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

private extension Session {
    var visibleStatus: String? {
        var parts: [String] = []
        if state != .activityUnknown { parts.append(state.label) }
        if pendingMessages > 0 { parts.append("\(pendingMessages) messages") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
