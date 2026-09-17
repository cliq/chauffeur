import SwiftUI

/// 02 / All active sessions, grouped by project then checkout.
struct SessionsView: View {
    var model: MobileAppModel

    var body: some View {
        List {
            if let staleSince = model.staleSince {
                Section {
                    StaleBanner(since: staleSince) {
                        model.reconnect()
                    }
                }
            }

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.connectionState.isConnected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(model.hostName ?? "Mac")
                        .font(.headline)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(connectionLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.connectionState.isConnected {
                        Button("Disconnect") { model.disconnect() }
                            .font(.caption)
                    }
                }
            }

            if let inventory = model.inventory {
                ForEach(inventory.projects) { project in
                    ProjectSection(model: model, inventory: inventory, project: project)
                }
            } else {
                ContentUnavailableView("No projects yet", systemImage: "folder", description: Text("Projects registered on your Mac appear here."))
            }
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refresh()
                }
                .disabled(!model.connectionState.isConnected)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New session", systemImage: "plus") {
                    model.path.append(.location(projectID: nil))
                }
                .disabled(model.inventory == nil)
            }
        }
        .refreshable {
            model.refresh()
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
        inventory.sessions(inProject: project.id)
    }

    /// Checkouts that have sessions, in folder order, each with its sessions.
    private var checkoutGroups: [(checkout: CheckoutSummary, folder: FolderSummary, sessions: [SessionSummary])] {
        project.folders.flatMap { folder in
            folder.checkouts.compactMap { checkout in
                let matching = sessions.filter { $0.checkoutID == checkout.id }
                return matching.isEmpty ? nil : (checkout, folder, matching)
            }
        }
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
                }
            } else {
                ForEach(checkoutGroups, id: \.checkout.id) { group in
                    CheckoutHeader(folder: group.folder, checkout: group.checkout)
                    ForEach(group.sessions) { session in
                        SessionRow(session: session) {
                            model.openSession(session.id)
                        }
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

private struct CheckoutHeader: View {
    let folder: FolderSummary
    let checkout: CheckoutSummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: checkout.kind == .main ? "arrow.triangle.branch" : "arrow.triangle.pull")
            Text(folder.name)
            Text("·")
            Text(checkout.branch)
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
    }

    private var detail: String {
        var parts = [session.branch, session.state.label]
        if session.isOpenOnMac {
            parts.append("Open on Mac")
        }
        return parts.joined(separator: " · ")
    }
}

struct KindBadge: View {
    let kind: SessionKind

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
    let since: Date
    var onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Disconnected · Last known list, not live", systemImage: "wifi.slash")
                .font(.subheadline.weight(.medium))
            Text("Stale since \(since.formatted(date: .omitted, time: .shortened)). The sessions can continue on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reconnect", action: onReconnect)
                .font(.subheadline)
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

#Preview("Stale") {
    let model = MobileAppModel.preview()
    model.disconnect()
    return NavigationStack {
        SessionsView(model: model)
    }
}
