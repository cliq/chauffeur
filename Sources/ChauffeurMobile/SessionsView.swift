import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// 02 / All live sessions, grouped by project then checkout. Projects without sessions still appear.
struct SessionsView: View {
    var model: MobileAppModel

    var body: some View {
        List {
            if model.inventoryIsStale {
                Section {
                    StaleBanner(isConnecting: model.isConnecting) {
                        Task { await model.connect() }
                    }
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
                    if model.isConnected {
                        Button("Disconnect") { model.disconnect() }
                            .font(.caption)
                    }
                }
            }

            if let inventory = model.inventory {
                let projects = inventory.projects.filter { !$0.archived }
                if projects.isEmpty {
                    ContentUnavailableView("No projects yet", systemImage: "folder", description: Text("Projects registered on your Mac appear here."))
                } else {
                    ForEach(projects) { project in
                        ProjectSection(model: model, inventory: inventory, project: project)
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

private struct ProjectSection: View {
    var model: MobileAppModel
    let inventory: InventorySnapshot
    let project: ProjectSummary

    private var sessions: [SessionSummary] {
        model.liveSessions.filter { $0.projectID == project.id }
    }

    /// Live sessions grouped by checkout path, in the order the project's folders list their
    /// checkouts; paths the inventory no longer lists come last.
    private var checkoutGroups: [CheckoutGroup] {
        var remaining = sessions
        var groups: [CheckoutGroup] = []
        for folder in project.folders {
            for checkout in folder.checkouts {
                let matching = remaining.filter { $0.checkoutPath == checkout.path }
                guard !matching.isEmpty else { continue }
                remaining.removeAll { $0.checkoutPath == checkout.path }
                groups.append(CheckoutGroup(path: checkout.path, folderName: folder.name, branch: checkout.branch, isMain: checkout.kind == .main, sessions: matching))
            }
        }
        while let orphan = remaining.first {
            let matching = remaining.filter { $0.checkoutPath == orphan.checkoutPath }
            remaining.removeAll { $0.checkoutPath == orphan.checkoutPath }
            let folderName = inventory.folder(orphan.folderID)?.name ?? URL(fileURLWithPath: orphan.checkoutPath).lastPathComponent
            groups.append(CheckoutGroup(path: orphan.checkoutPath, folderName: folderName, branch: orphan.branch ?? "checkout", isMain: false, sessions: matching))
        }
        return groups
    }

    var body: some View {
        Section {
            if sessions.isEmpty {
                HStack {
                    Text("No active sessions")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Launch here") {
                        model.path.append(.location(projectID: project.id))
                    }
                    .font(.subheadline)
                    .disabled(!model.isConnected)
                }
            } else {
                ForEach(checkoutGroups) { group in
                    CheckoutHeader(group: group)
                    ForEach(group.sessions) { session in
                        SessionRow(session: session) {
                            model.openSession(session.id)
                        }
                        .disabled(!model.isConnected)
                    }
                }
            }
        } header: {
            HStack {
                Text(project.name)
                Spacer()
                Text("\(sessions.count) active")
            }
        }
    }
}

private struct CheckoutGroup: Identifiable {
    var path: String
    var folderName: String
    var branch: String
    var isMain: Bool
    var sessions: [SessionSummary]

    var id: String { path }
}

private struct CheckoutHeader: View {
    let group: CheckoutGroup

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.isMain ? "arrow.triangle.branch" : "arrow.triangle.pull")
            Text(group.folderName)
            Text("·")
            Text(group.branch)
        }
        .font(.caption.smallCaps())
        .foregroundStyle(.secondary)
        .listRowSeparator(.hidden, edges: .bottom)
    }
}

struct SessionRow: View {
    let session: SessionSummary
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.body.weight(.medium))
                        KindBadge(kind: session.kind)
                        if session.attached {
                            Text("In use")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("In use on another device")
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.needsAttention {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                        .accessibilityLabel("Needs attention")
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-row")
    }

    private var detail: String {
        var parts: [String] = []
        if let branch = session.branch {
            parts.append(branch)
        }
        parts.append(session.state.label)
        return parts.joined(separator: " · ")
    }
}

struct KindBadge: View {
    let kind: RemoteSessionKind

    var body: some View {
        Text(kind.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch kind {
        case .codex: .blue
        case .claude: .orange
        case .shell: .gray
        }
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
