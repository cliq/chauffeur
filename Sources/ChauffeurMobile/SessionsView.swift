import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// 02 / All live sessions, grouped by project then checkout.
struct SessionsView: View {
    var model: MobileAppModel
    @State private var showingSettings = false
    /// Mirrors the desktop sidebar's "Show terminal sessions"; off leaves only agents.
    @AppStorage("sessions.showsTerminalSessions") private var showsTerminalSessions = true
    /// Comma-separated IDs of the projects and sidebar groups the user collapsed.
    @AppStorage("sessions.collapsedProjects") private var collapsedProjects = ""
    @AppStorage("sessions.collapsedGroups") private var collapsedGroups = ""

    private var visibleSessions: [SessionSummary] {
        showsTerminalSessions ? model.liveSessions : model.liveSessions.filter { $0.kind != .shell }
    }

    var body: some View {
        List {
            if model.inventoryIsStale {
                Section {
                    StaleBanner(isConnecting: model.isConnecting) {
                        Task { await model.connect() }
                    }
                }
            }

            if let error = model.connectError {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") { model.connectError = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    .accessibilityIdentifier("sessions-error")
                }
            }

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.hostName ?? "Mac")
                        .font(.headline)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(connectionLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings.open")
                }
                Toggle("Show terminal sessions", isOn: $showsTerminalSessions)
                    .accessibilityIdentifier("sessions.showTerminals")
            }

            if let inventory = model.inventory {
                let sessions = visibleSessions
                let activeProjectIDs = Set(sessions.map(\.projectID))
                let projects = inventory.projects.filter { !$0.archived && activeProjectIDs.contains($0.id) }
                if projects.isEmpty {
                    if model.liveSessions.isEmpty {
                        ContentUnavailableView("No active sessions", systemImage: "terminal", description: Text("Tap + to start a new session."))
                    } else {
                        ContentUnavailableView("No active agent sessions", systemImage: "terminal", description: Text("Terminal sessions are hidden."))
                    }
                } else {
                    ForEach(projects) { project in
                        ProjectSections(model: model, inventory: inventory, project: project, liveSessions: sessions,
                                       isExpanded: CollapsedIDs(storage: $collapsedProjects).isExpanded(project.id),
                                       collapsedGroups: CollapsedIDs(storage: $collapsedGroups))
                    }
                }
            } else if model.isConnecting {
                HStack {
                    ProgressView()
                    Text("Loading sessions…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("Not connected", systemImage: "wifi.slash", description: Text("Connect to your Mac to see its sessions."))
            }
        }
        .accessibilityIdentifier("sessions-list")
        // Projects open on an empty titled section; keep their group cards close beneath.
        .listSectionSpacing(.compact)
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshInventory() }
                }
                .disabled(!model.isConnected)
                .accessibilityIdentifier("sessions-refresh")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New session", systemImage: "plus") {
                    model.path.append(.location(projectID: nil))
                }
                .disabled(model.inventory == nil || !model.isConnected)
                .accessibilityIdentifier("sessions-new")
            }
        }
        .refreshable {
            await model.refreshInventory()
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                Form {
                    KeepAwakeControls(
                        status: model.inventory?.keepAwake,
                        availability: keepAwakeAvailability,
                        pending: model.keepAwakeMutationPending,
                        mutationError: model.keepAwakeMutationError,
                        setSettings: { await model.setKeepAwakeSettings($0) },
                        setTimer: { await model.setKeepAwakeTimer(until: $0) }
                    )
                    Section {
                        Button("Disconnect", role: .destructive) {
                            showingSettings = false
                            model.disconnect()
                        }
                        .disabled(!model.isConnected)
                        .accessibilityIdentifier("settings.disconnect")
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingSettings = false }
                    }
                }
            }
        }
    }

    private var keepAwakeAvailability: KeepAwakeAvailability {
        guard model.isConnected, !model.inventoryIsStale else { return .disconnected }
        return model.keepAwakeIsSupported ? .available : .unsupported
    }

    private var connectionLabel: String {
        switch model.connectionState {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .unavailable: "Unavailable"
        }
    }
}

/// A comma-separated set of IDs in app storage: the projects or groups the user collapsed.
private struct CollapsedIDs {
    var storage: Binding<String>

    private var ids: Set<String> { Set(storage.wrappedValue.split(separator: ",").map(String.init)) }

    func isExpanded(_ id: UUID) -> Binding<Bool> {
        Binding {
            !ids.contains(id.uuidString)
        } set: { expanded in
            var updated = ids
            if expanded { updated.remove(id.uuidString) } else { updated.insert(id.uuidString) }
            storage.wrappedValue = updated.sorted().joined(separator: ",")
        }
    }
}

/// A project's live sessions without nesting: a collapsible project title, then
/// each run of repositories that share a sidebar group under that group's
/// collapsible breadcrumb, with a card per repository under its name. Sessions name
/// only their checkout, since most checkouts hold a single session.
private struct ProjectSections: View {
    var model: MobileAppModel
    let inventory: InventorySnapshot
    let project: ProjectSummary
    let liveSessions: [SessionSummary]
    @Binding var isExpanded: Bool
    let collapsedGroups: CollapsedIDs

    private var sessions: [SessionSummary] {
        liveSessions.filter { $0.projectID == project.id }
    }

    var body: some View {
        Section {} header: {
            CollapsingHeader(isExpanded: $isExpanded, count: sessions.count, needsAttention: sessions.contains(where: \.needsAttention)) {
                Text(project.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .textCase(nil)
            .accessibilityIdentifier("sessions.project.\(project.id)")
        }
        .headerProminence(.increased)
        if isExpanded {
            ForEach(SessionRun.runs(project: project, inventory: inventory, sessions: sessions)) { run in
                let expanded = run.group.map { collapsedGroups.isExpanded($0.id) }
                if let group = run.group, let expanded {
                    Section {} header: {
                        CollapsingHeader(isExpanded: expanded, count: run.sessionCount, needsAttention: run.needsAttention) {
                            Label {
                                Text(run.path.map(\.name).joined(separator: " › "))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "rectangle.stack").foregroundStyle(.secondary)
                            }
                        }
                        .textCase(nil)
                        .accessibilityIdentifier("sessions.group.\(group.id)")
                    }
                    .headerProminence(.increased)
                }
                if expanded?.wrappedValue ?? true {
                    ForEach(run.repositories) { repository in
                        Section {
                            ForEach(repository.entries) { entry in
                                SessionRow(session: entry.session, location: entry.location) {
                                    model.openSession(entry.session.id)
                                }
                                .disabled(!model.isConnected)
                            }
                        } header: {
                            RepositoryHeader(name: repository.name)
                        }
                    }
                }
            }
        }
    }
}

/// A tappable project or group title that folds its content away, keeping the
/// session count and whether any of them needs attention.
private struct CollapsingHeader<Title: View>: View {
    @Binding var isExpanded: Bool
    let count: Int
    let needsAttention: Bool
    @ViewBuilder var title: Title
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                title
                Spacer(minLength: 8)
                if needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("\(count)")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue("\(count) active\(needsAttention ? ", needs attention" : ""), \(isExpanded ? "expanded" : "collapsed")")
        .accessibilityHint(isExpanded ? "Collapses" : "Expands")
    }
}

/// Names the repository whose sessions fill the card below it.
private struct RepositoryHeader: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "folder")
            .labelStyle(RepositoryLabelStyle())
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("sessions.repository")
    }
}

private struct RepositoryLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon; configuration.title }
    }
}

/// Where a session runs: its checkout, and its repository when no divider names it.
struct SessionLocation {
    var repository: String?
    var branch: String?
    var kind: CheckoutKind
    var isRepository: Bool
}

/// Consecutive repositories in the same sidebar group, with their live sessions.
private struct SessionRun: Identifiable {
    struct Entry: Identifiable {
        var session: SessionSummary
        var location: SessionLocation
        var id: UUID { session.id }
    }
    struct Repository: Identifiable {
        let id: String
        let name: String
        var entries: [Entry]
    }
    let id: String
    /// The enclosing groups, outermost first; empty for repositories outside any group.
    let path: [RepositoryGroupSummary]
    var repositories: [Repository]

    var group: RepositoryGroupSummary? { path.last }
    var sessionCount: Int { repositories.reduce(0) { $0 + $1.entries.count } }
    var needsAttention: Bool { repositories.contains { $0.entries.contains { $0.session.needsAttention } } }

    /// Runs in the Mac sidebar's order, sessions in each folder in its checkouts'
    /// order; sessions in folders the inventory no longer lists come last.
    static func runs(project: ProjectSummary, inventory: InventorySnapshot, sessions: [SessionSummary]) -> [SessionRun] {
        var remaining = sessions
        var runs: [SessionRun] = []
        func append(_ repository: Repository, path: [RepositoryGroupSummary]) {
            guard !repository.entries.isEmpty else { return }
            if let last = runs.last, last.path.map(\.id) == path.map(\.id) { runs[runs.count - 1].repositories.append(repository); return }
            runs.append(SessionRun(id: path.last.map { "group:\($0.id)" } ?? "ungrouped:\(runs.count)", path: path, repositories: [repository]))
        }
        for folder in project.folders {
            var entries: [Entry] = []
            for checkout in folder.checkouts {
                let matching = remaining.filter { $0.checkoutPath == checkout.path }
                remaining.removeAll { $0.checkoutPath == checkout.path }
                entries += matching.map { Entry(session: $0, location: SessionLocation(branch: checkout.branch, kind: checkout.kind, isRepository: folder.isRepository)) }
            }
            // Sessions in checkouts the inventory no longer lists.
            entries += remaining.filter { $0.folderID == folder.id }.map {
                Entry(session: $0, location: SessionLocation(branch: $0.branch, kind: $0.worktreeID == nil ? .main : .worktree, isRepository: folder.isRepository))
            }
            remaining.removeAll { $0.folderID == folder.id }
            append(Repository(id: folder.id.uuidString, name: folder.name, entries: entries),
                   path: project.groupPath(of: folder))
        }
        // Sessions in folders the inventory no longer lists, one divider per folder.
        var unlisted: [Repository] = []
        for session in remaining {
            let name = inventory.folder(session.folderID)?.name ?? URL(fileURLWithPath: session.checkoutPath).lastPathComponent
            let entry = Entry(session: session, location: SessionLocation(branch: session.branch, kind: session.worktreeID == nil ? .main : .worktree, isRepository: true))
            if let index = unlisted.firstIndex(where: { $0.id == session.folderID.uuidString }) { unlisted[index].entries.append(entry) }
            else { unlisted.append(Repository(id: session.folderID.uuidString, name: name, entries: [entry])) }
        }
        unlisted.forEach { append($0, path: []) }
        return runs
    }
}

/// A session: its state as an icon and words, its title and agent, where it runs,
/// and progress when it reports some.
struct SessionRow: View {
    let session: SessionSummary
    var location: SessionLocation?
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SessionStateIcon(session: session)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(session.title)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        KindBadge(kind: session.kind)
                    }
                    if let location {
                        SessionLocationLine(repository: location.repository, branch: location.branch, kind: location.kind, isRepository: location.isRepository)
                    }
                    statusLine
                    if let progress = session.progress {
                        if let percent = progress.percentComplete {
                            ProgressView(value: Double(percent), total: 100) {
                                Text(progress.now.isEmpty ? progress.title : progress.now).lineLimit(1)
                            } currentValueLabel: {
                                Text("\(percent)%").monospacedDigit()
                            }
                            .font(.caption)
                            .accessibilityLabel("Implementation progress")
                            .accessibilityValue("\(percent) percent. \(progress.now)")
                            .accessibilityIdentifier("session-progress")
                        } else {
                            Label("Progress unavailable", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-row")
    }

    @ViewBuilder private var statusLine: some View {
        let state = stateText
        if state != nil || session.attached {
            HStack(spacing: 6) {
                if let state {
                    Text(state).foregroundStyle(session.needsAttention ? Color.orange : .secondary)
                }
                if state != nil, session.attached {
                    Text("·").foregroundStyle(.tertiary)
                }
                if session.attached {
                    Text("In use")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("In use on another device")
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    private var stateText: String? {
        guard session.state != .activityUnknown else { return session.needsAttention ? "Needs attention" : nil }
        if session.needsAttention, session.state != .needsAttention { return "\(session.state.label) · Needs attention" }
        return session.state.label
    }
}

/// The session state's shape and color; the row spells the state out beside it.
private struct SessionStateIcon: View {
    let session: SessionSummary

    var body: some View {
        let (symbol, color) = appearance
        Image(systemName: symbol)
            .font(.subheadline)
            .foregroundStyle(color)
            .frame(width: 20)
            .accessibilityHidden(true)
    }

    private var appearance: (String, Color) {
        if session.state == .failed { return ("xmark.circle.fill", .red) }
        if session.needsAttention || session.state == .needsAttention { return ("exclamationmark.circle.fill", .orange) }
        switch session.state {
        case .running: return ("play.circle.fill", .green)
        case .starting: return ("circle.dotted", .secondary)
        case .turnFinished: return ("checkmark.circle.fill", .blue)
        case .exited, .interrupted: return ("stop.circle", .secondary)
        default: return ("circle", .secondary)
        }
    }
}

struct KindBadge: View {
    let kind: RemoteSessionKind

    var body: some View {
        AgentBadge(label: kind.label, color: AgentBadge.color(named: kind.badgeColorName))
    }
}

struct StaleBanner: View {
    var isConnecting: Bool
    var onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Disconnected · Last known list, not live", systemImage: "wifi.slash")
                .font(.subheadline.weight(.medium))
            Text("The sessions can continue on your Mac. Reconnect to see their current state.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(isConnecting ? "Reconnecting…" : "Reconnect", action: onReconnect)
                .font(.subheadline)
                .disabled(isConnecting)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.yellow.opacity(0.15))
    }
}

#Preview("Connected") {
    NavigationStack {
        SessionsView(model: .preview())
    }
}

#Preview("Saved host, not connected") {
    NavigationStack {
        SessionsView(model: .preview(connected: false))
    }
}
