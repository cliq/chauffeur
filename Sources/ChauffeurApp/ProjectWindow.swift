import SwiftUI
import AppKit
import Combine
import ChauffeurCore

@MainActor final class ProjectLayout: ObservableObject {
    @Published var state: WindowState
    @Published var selectedFolderID: UUID?
    @Published var selectedWorktreePath: String?
    @Published var search = ""
    @Published var detailsVisible = false
    var controllers: [UUID: TerminalController] = [:]
    weak var window: NSWindow?
    var loaded = false
    init(projectID: UUID) { state = WindowState(projectID: projectID) }
    func controller(for id: UUID, scrollback: Int) -> TerminalController {
        if let controller = controllers[id] { return controller }
        let controller = TerminalController(sessionID: id, scrollback: scrollback); controllers[id] = controller; return controller
    }
    func select(_ id: UUID) {
        if !state.tabs.contains(id) { state.tabs.append(id) }
        if state.splitSessionID == id { state.splitSessionID = state.selectedSessionID }
        state.selectedSessionID = id
    }
    func closeTab(_ id: UUID) {
        controllers[id]?.detach(); controllers.removeValue(forKey: id)
        state.tabs.removeAll { $0 == id }
        if state.splitSessionID == id { state.splitSessionID = nil }
        if state.selectedSessionID == id { state.selectedSessionID = state.tabs.last }
    }
    func toggleSplit() {
        if state.splitSessionID != nil { state.splitSessionID = nil }
        else { state.splitSessionID = state.tabs.first { $0 != state.selectedSessionID } }
    }
    func synchronizeTerminals(model: AppModel) {
        let visible = Set([state.selectedSessionID, state.splitSessionID].compactMap { $0 }.filter { model.session($0)?.state.isLive == true })
        for (id, controller) in controllers where !visible.contains(id) { controller.detach() }
        for id in visible { controller(for: id, scrollback: model.snapshot.settings.scrollbackLines).attach(socketPath: model.socketPath) }
    }
}

struct ProjectWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var layout: ProjectLayout
    let projectID: UUID
    @State private var launching = false
    @State private var launchingInNewWorktree = false
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
    private var sessions: [Session] {
        model.sessions(in: projectID).filter { (layout.state.selectedGroupID == nil || $0.groupID == layout.state.selectedGroupID) && (layout.search.isEmpty || $0.title.localizedCaseInsensitiveContains(layout.search) || $0.launch.workingDirectory.localizedCaseInsensitiveContains(layout.search)) }
    }
    var body: some View {
        Group {
            if let project {
                NavigationSplitView(columnVisibility: Binding(get: { layout.state.sidebarVisible ? .all : .detailOnly }, set: { layout.state.sidebarVisible = $0 != .detailOnly })) {
                    sidebar(project)
                } detail: {
                    VStack(spacing: 0) {
                        if !model.online { ServiceHealthView().padding(10).background(.orange.opacity(0.12)); Divider() }
                        header(project)
                        tabs
                        HSplitView {
                            terminalArea
                            if layout.detailsVisible, let session = model.session(layout.state.selectedSessionID) { SessionDetailsView(session: session, project: project).frame(minWidth: 300, idealWidth: 340, maxWidth: 460) }
                        }
                    }
                }
                .navigationTitle(project.name)
                .toolbar {
                    ToolbarItemGroup {
                        Button { showLaunch() } label: { Label("New Session", systemImage: "plus") }.disabled(!model.online || project.archived)
                        Button { layout.toggleSplit() } label: { Label("Split Terminal", systemImage: "rectangle.split.2x1") }.disabled(layout.state.tabs.count < 2 && layout.state.splitSessionID == nil)
                        Button { layout.detailsVisible.toggle() } label: { Label("Session Details", systemImage: "sidebar.right") }
                        Menu {
                            Button("Project Settings…") { editingProject = true }
                            Button("Manage Groups…") { editingGroups = true }
                            Button("Manage Worktrees…") { showWorktrees(folderID: layout.selectedFolderID) }
                            Button("Open Another Project…") { openWindow(id: "welcome") }
                        } label: { Label("Project Actions", systemImage: "ellipsis.circle") }
                    }
                }
                .sheet(isPresented: $launching) { SessionLaunchView(project: project, initialGroupID: layout.state.selectedGroupID, initialFolderID: layout.selectedFolderID, startsInNewWorktree: launchingInNewWorktree, worktreeCreated: revealCreatedWorktree) { layout.select($0) } }
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
            .onChange(of: layout.state.selectedSessionID) { _, id in
                if let id { revealSessionCheckout(id) }
                else { layout.selectedWorktreePath = nil }
            }
            .onChange(of: model.snapshot.store.worktrees.map(\.value.id)) { _, ids in
                if let pendingWorktree, ids.contains(pendingWorktree.id) { self.pendingWorktree = nil }
            }
            .onChange(of: model.snapshot.sessions) { _, _ in if layout.loaded { layout.synchronizeTerminals(model: model) } }
            .onReceive(NotificationCenter.default.publisher(for: .chauffeurCommand)) { notification in
                guard layout.window?.isKeyWindow == true, let command = notification.object as? String else { return }
                switch command {
                case "new-session": showLaunch()
                case "split": layout.toggleSplit()
                case "search-sessions": layout.state.sidebarVisible = true; searchFocused = true
                case "find": if let id = layout.state.selectedSessionID { layout.controllers[id]?.find() }
                case "next": cycle(1)
                case "previous": cycle(-1)
                case "attention": nextAttention()
                default: break
                }
            }
    }
    private func sidebar(_ project: Project) -> some View {
        VStack(spacing: 0) {
            Picker("Agent group", selection: $layout.state.selectedGroupID) {
                Text("All Groups").tag(UUID?.none)
                ForEach(project.groups.filter { !$0.archived || $0.id == layout.state.selectedGroupID }) { group in Text(group.name).tag(Optional(group.id)) }
            }.padding(12)
            TextField("Search sessions", text: $layout.search).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 8).focused($searchFocused)
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
                    if sessions.contains(where: \.needsAttention) {
                        Section("Needs Attention") {
                            ForEach(sessions.filter(\.needsAttention)) { session in sessionRow(session, project: project) }
                        }
                    }
                    Section("Sessions") {
                        ForEach(sessions) { session in sessionRow(session, project: project) }
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
            Text("Closing a tab or window keeps agents running.").font(.caption2).foregroundStyle(.secondary).padding(12)
        }.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 370)
    }
    private struct SidebarWorktree: Identifiable {
        let path: String
        let branch: String
        let availability: Availability
        var id: String { path }
    }
    private func worktrees(for folder: ProjectFolder, project: Project) -> [SidebarWorktree] {
        let stored = model.snapshot.store.worktrees.map(\.value)
        var records = stored.filter { $0.projectID == project.id && $0.folderID == folder.id && $0.registered }
        // Bridge the creation response until the next store snapshot arrives.
        if let pendingWorktree, pendingWorktree.folderID == folder.id,
           !stored.contains(where: { $0.id == pendingWorktree.id }) { records.append(pendingWorktree) }
        let inventory = model.snapshot.repositoryInventories?.first { $0.sourcePath == folder.canonicalPath || $0.sourcePaths?.contains(folder.canonicalPath) == true }
        var rows = records.map { SidebarWorktree(path: $0.path, branch: $0.branch, availability: $0.availability) }
        for entry in inventory?.entries ?? [] where !records.contains(where: { $0.path == entry.path || (entry.gitIdentity != nil && $0.gitIdentity == entry.gitIdentity) }) {
            rows.append(SidebarWorktree(path: entry.path, branch: entry.branch, availability: entry.availability ?? .available))
        }
        // The repository row already represents its registered checkout.
        return rows.filter { $0.path != folder.canonicalPath }.sorted { $0.branch.localizedStandardCompare($1.branch) == .orderedAscending }
    }
    private func repositoryRow(_ folder: ProjectFolder, project: Project) -> some View {
        let trees = worktrees(for: folder, project: project)
        return DisclosureGroup(isExpanded: Binding(get: { !collapsedRepositories.contains(folder.id) }, set: { if $0 { collapsedRepositories.remove(folder.id) } else { collapsedRepositories.insert(folder.id) } })) {
            if trees.isEmpty {
                Text("No worktrees").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(trees) { tree in
                let selected = layout.selectedFolderID == folder.id && layout.selectedWorktreePath == tree.path
                Button { revealCheckout(folderID: folder.id, worktreePath: tree.path); showWorktrees(folderID: folder.id) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tree.branch.isEmpty ? "Detached HEAD" : tree.branch).lineLimit(1)
                            Text(URL(fileURLWithPath: tree.path).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if tree.availability != .available { Text(tree.availability.rawValue.capitalized).font(.caption).foregroundStyle(.orange) }
                        }
                    } icon: { Image(systemName: "arrow.triangle.branch") }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help(tree.path).accessibilityIdentifier("repository.worktree.\(tree.path)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityValue(selected ? "Selected worktree" : "")
                    .id(SidebarRowID.worktree(folder.id, tree.path))
                    .contextMenu {
                        Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) }
                        Button("Reveal in Finder") { FilePanels.reveal(tree.path) }.disabled(tree.availability != .available)
                    }
            }
            Button("New Worktree & Session…", systemImage: "plus") { showLaunch(folderID: folder.id, newWorktree: true) }
                .buttonStyle(.plain).font(.caption).disabled(!model.online || project.archived || folder.availability != .available)
                .accessibilityIdentifier("repository.new-worktree.\(folder.id)")
        } label: {
            Button { layout.selectedFolderID = folder.id; layout.selectedWorktreePath = nil } label: {
                Label { Text(folder.name).foregroundStyle(layout.selectedFolderID == folder.id ? Color.accentColor : Color.primary) } icon: { Image(systemName: FileManager.default.isReadableFile(atPath: folder.canonicalPath) ? "folder" : "folder.badge.questionmark") }
            }.buttonStyle(.plain).help(folder.selectedPath).accessibilityIdentifier("repository.\(folder.id)")
                .contextMenu {
                    Button("New Session Here…") { showLaunch(folderID: folder.id) }
                    Button("New Worktree & Session…") { showLaunch(folderID: folder.id, newWorktree: true) }
                        .disabled(!model.online || project.archived || folder.availability != .available)
                    Button("Manage Worktrees…") { showWorktrees(folderID: folder.id) }
                    Button("Relink / Edit Folder…") { editingProject = true }
                    Button("Reveal in Finder") { FilePanels.reveal(folder.selectedPath) }
                }
        }.id(SidebarRowID.repository(folder.id))
    }
    private func revealCreatedWorktree(_ tree: Worktree) {
        guard tree.projectID == projectID, tree.registered else { return }
        pendingWorktree = model.snapshot.store.worktrees.contains { $0.value.id == tree.id } ? nil : tree
        revealCheckout(folderID: tree.folderID, worktreePath: tree.path)
    }
    private func revealCheckout(folderID: UUID, worktreePath: String?, showSidebar: Bool = true) {
        layout.selectedFolderID = folderID
        layout.selectedWorktreePath = worktreePath
        collapsedRepositories.remove(folderID)
        if showSidebar { layout.state.sidebarVisible = true }
        sidebarReveal = SidebarReveal(row: worktreePath.map { .worktree(folderID, $0) } ?? .repository(folderID))
    }
    private func revealSessionCheckout(_ id: UUID) {
        guard let session = model.session(id), session.projectID == projectID,
              let folder = project?.folders.first(where: { $0.id == session.folderID && $0.registered }) else { return }
        let path = model.snapshot.store.worktrees.first { $0.value.id == session.worktreeID }?.value.path ?? session.launch.workingDirectory
        revealCheckout(folderID: folder.id, worktreePath: path == folder.canonicalPath ? nil : path, showSidebar: false)
    }
    private func showWorktrees(folderID: UUID?) {
        worktreeSheet = WorktreeSheet(folderID: folderID)
    }
    private func sessionRow(_ session: Session, project: Project) -> some View {
        Button { select(session.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Image(systemName: session.parentID == nil ? "terminal" : "arrow.turn.down.right"); Text(session.title).lineLimit(1).fontWeight(session.id == layout.state.selectedSessionID ? .semibold : .regular) }
                Text("\(session.launch.preset.name) · \(project.groups.first { $0.id == session.groupID }?.name ?? "Group unavailable")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(session.state.label + (session.pendingMessages > 0 ? " · \(session.pendingMessages) messages" : "")).font(.caption).foregroundStyle(session.needsAttention ? .orange : .secondary)
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(session.title)\n\(session.launch.workingDirectory)\n\(session.launch.configurationPath)")
            .contextMenu {
                Button("Open Terminal") { select(session.id) }
                Button("Session Details") { select(session.id); layout.detailsVisible = true }
                if session.state.isLive { Button("Stop Session…") { select(session.id); layout.detailsVisible = true } }
            }
    }
    private func header(_ project: Project) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) { Text(project.name).font(.headline); Text(model.setName(project.presetSetID)).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let session = model.session(layout.state.selectedSessionID) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(session.launch.workingDirectory).font(.system(.caption, design: .monospaced)).lineLimit(1).help(session.launch.workingDirectory)
                    if let tree = model.snapshot.store.worktrees.first(where: { $0.value.id == session.worktreeID })?.value { Text(tree.branch).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(12)
    }
    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(layout.state.tabs, id: \.self) { id in
                    if let session = model.session(id) {
                        HStack(spacing: 10) {
                            Button(session.title) { select(id) }.buttonStyle(.plain).lineLimit(1)
                            Button { layout.closeTab(id) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).help("Close tab — agent keeps running")
                        }.padding(.horizontal, 12).padding(.vertical, 9).background(layout.state.selectedSessionID == id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.padding(.horizontal, 8)
        }.scrollIndicators(.hidden).frame(height: 42).background(.bar)
    }
    @ViewBuilder private var terminalArea: some View {
        if let selected = model.session(layout.state.selectedSessionID) {
            HSplitView {
                // Stable sibling identities let a terminal move between panes
                // without two representables briefly hosting the same NSView.
                ForEach([selected] + [model.session(layout.state.splitSessionID)].compactMap { $0 }.filter { $0.id != selected.id }) { session in
                    TerminalPane(session: session, controller: layout.controller(for: session.id, scrollback: model.snapshot.settings.scrollbackLines)).frame(minWidth: 240)
                }
            }
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView("Ready for a session", systemImage: "terminal", description: Text("Choose an existing session in the sidebar or launch an agent using this project's presets."))
                Button("New Session…") { showLaunch() }.buttonStyle(.borderedProminent).disabled(!model.online || project?.archived == true)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func restore() {
        guard model.online, !layout.loaded, project != nil else { return }
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
        layout.state.tabs = layout.state.tabs.filter { model.session($0)?.projectID == projectID }
        if !layout.state.tabs.contains(where: { $0 == layout.state.selectedSessionID }) { layout.state.selectedSessionID = layout.state.tabs.first }
        if layout.state.splitSessionID == layout.state.selectedSessionID { layout.state.splitSessionID = nil }
        layout.state.wasOpen = true; model.projectOpened(projectID); saveLayout()
        layout.synchronizeTerminals(model: model)
        consumeSessionRoute()
        consumeProjectRoute()
    }
    private func consumeProjectRoute() {
        guard layout.loaded, model.online, let navigation = model.pendingProjectRoute,
              navigation.match.projectID == projectID else { return }
        layout.selectedFolderID = navigation.match.folderID
        collapsedRepositories.remove(navigation.match.folderID)
        layout.state.sidebarVisible = true
        model.pendingProjectRoute = nil
        dismissWindow(id: "welcome")
        layout.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func consumeSessionRoute() {
        guard layout.loaded, model.online, let navigation = model.pendingSessionRoute,
              navigation.route.projectID == projectID,
              let session = model.session(navigation.route.sessionID), session.projectID == projectID else { return }
        layout.search = ""; layout.state.selectedGroupID = session.groupID
        layout.state.sidebarVisible = true
        layout.state.splitSessionID = nil
        select(session.id)
        model.pendingSessionRoute = nil
        dismissWindow(id: "welcome")
        layout.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func saveLayout() { if layout.loaded { model.saveWindow(layout.state) } }
    private func showLaunch(folderID: UUID? = nil, newWorktree: Bool = false) {
        if let folderID { layout.selectedFolderID = folderID }
        launchingInNewWorktree = newWorktree; launching = true
    }
    private func select(_ id: UUID) {
        if layout.state.selectedSessionID == id { revealSessionCheckout(id) }
        layout.select(id)
        model.perform { _ = try await model.call("markRead", .object(["sessionID": .string(id.uuidString)])) }
    }
    private func cycle(_ offset: Int) {
        guard !layout.state.tabs.isEmpty else { return }
        let current = layout.state.tabs.firstIndex { $0 == layout.state.selectedSessionID } ?? 0
        select(layout.state.tabs[(current + offset + layout.state.tabs.count) % layout.state.tabs.count])
    }
    private func nextAttention() {
        let attention = sessions.filter(\.needsAttention)
        guard !attention.isEmpty else { return }
        let next = attention.firstIndex { $0.id == layout.state.selectedSessionID }.map { ($0 + 1) % attention.count } ?? 0
        select(attention[next].id)
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
