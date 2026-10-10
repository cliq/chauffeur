import SwiftUI
import AppKit
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient
import ChauffeurTerminalInterface

/// One paired server's window: its live sessions, launching new ones, and their terminals.
/// Everything runs on the server. Closing the window detaches its terminals and disconnects.
struct RemoteHostWindow: View {
    var store: RemoteHostStore
    let hostID: UUID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let model = store.model(for: hostID) {
            RemoteHostContent(model: model)
        } else {
            ContentUnavailableView {
                Label("Server Not Paired", systemImage: "server.rack")
            } description: {
                Text("This server was forgotten on this Mac. Pair it again to reconnect.")
            } actions: {
                Button("Remote Servers…") { openWindow(id: "remote-servers") }
            }
            .frame(minWidth: 480, minHeight: 320)
            .navigationTitle("Remote Server")
        }
    }
}

private struct RemoteHostContent: View {
    @Bindable var model: RemoteHostModel
    @State private var launching = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.inventory == nil {
                RemoteConnectingView(model: model)
            } else {
                NavigationSplitView {
                    RemoteSessionSidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 280)
                } detail: {
                    if let id = model.selectedSessionID, let session = model.session(id) {
                        RemoteTerminalPane(model: model, session: session).id(id)
                    } else {
                        ContentUnavailableView("No Session Selected", systemImage: "terminal", description: Text("Choose a session, or start a new one on \(model.hostName)."))
                    }
                }
                .sheet(isPresented: $launching) {
                    RemoteLaunchSheet(model: model)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if !model.isConnected && !model.isConnecting {
                    Button { Task { await model.connect() } } label: { Label("Reconnect", systemImage: "bolt.horizontal.circle") }
                        .help(model.connectionMessage ?? "Reconnect to \(model.hostName)")
                }
                Button { launching = true } label: { Label("New Session", systemImage: "plus") }
                    .disabled(!model.isConnected || model.inventory == nil)
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .help("Start an agent or shell on \(model.hostName)")
                Button { Task { await model.refreshInventory() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!model.isConnected)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .navigationTitle(model.hostName)
        .navigationSubtitle(status)
        .task { if !model.isConnected { await model.connect() } }
        .onChange(of: model.liveSessions.map(\.id)) { model.pruneTerminals() }
        .onDisappear { model.disconnect() }
    }

    private var status: String {
        let address = "\(model.savedHost.host):\(String(model.savedHost.port))"
        switch model.connectionState {
        case .connected: return model.inventoryIsStale ? "Updating · \(address)" : "Connected · \(address)"
        case .connecting: return "Connecting · \(address)"
        case .disconnected, .unavailable: return "Disconnected · \(address)"
        }
    }
}

/// Shown until the first inventory arrives: progress, or why the connection failed.
private struct RemoteConnectingView: View {
    var model: RemoteHostModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let message = model.connectionMessage, !model.isConnecting {
            ContentUnavailableView {
                Label("Couldn’t Connect", systemImage: "bolt.horizontal.circle")
            } description: {
                Text(message)
            } actions: {
                Button("Reconnect") { Task { await model.connect() } }.keyboardShortcut(.defaultAction)
                Button("Remote Servers…") { openWindow(id: "remote-servers") }
            }
        } else {
            ProgressView("Connecting to \(model.hostName)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Remote Servers

/// Lists paired servers and pairs new ones. Opening a server shows its own window.
struct RemoteServersView: View {
    var store: RemoteHostStore
    @Environment(\.openWindow) private var openWindow
    @State private var address = ""
    @State private var port = String(RemoteHostStore.defaultPort)
    @State private var code = ""
    @State private var forgetting: SavedHost?

    private var normalizedCode: String? { PairingKeyDerivation.normalize(code) }

    var body: some View {
        Form {
            Section("Paired servers") {
                if store.savedHosts.isEmpty {
                    Text("No servers yet. Pair one below.").foregroundStyle(.secondary)
                }
                ForEach(store.savedHosts) { host in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.name).fontWeight(.medium)
                            Text("\(host.host):\(String(host.port))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { openWindow(id: "remote-host", value: host.hostID) }
                        Button("Forget…", role: .destructive) { forgetting = host }
                    }
                }
            }
            Section {
                TextField("Address", text: $address, prompt: Text("10.0.1.63 or name.local"))
                TextField("Port", text: $port)
                TextField("Pairing code", text: $code, prompt: Text("XXXX-XXXX-XX"))
                    .font(.body.monospaced())
                HStack {
                    Spacer()
                    if store.isPairing { ProgressView().controlSize(.small) }
                    Button("Pair and Open") { Task { await pair() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.isPairing || address.trimmingCharacters(in: .whitespaces).isEmpty || normalizedCode == nil || !RemoteHostStore.validPorts.contains(Int(port) ?? 0))
                }
            } header: {
                Text("Pair a server")
            } footer: {
                Text("On a Linux server, run Scripts/linux/pair.sh to print a code. On a Mac, use Settings ▸ Remote Access ▸ Pair iPhone…. Codes expire after 120 seconds.")
                    .foregroundStyle(.secondary)
            }
            if let message = store.error {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420)
        .navigationTitle("Remote Servers")
        .confirmationDialog("Forget \(forgetting?.name ?? "this server")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), presenting: forgetting) { host in
            Button("Forget", role: .destructive) { store.forget(host.hostID) }
        } message: { _ in
            Text("Its window closes its terminals. The server keeps this Mac as a device until you revoke it there.")
        }
    }

    private func pair() async {
        guard let id = await store.pair(host: address, port: Int(port) ?? RemoteHostStore.defaultPort, code: code) else { return }
        code = ""
        address = ""
        openWindow(id: "remote-host", value: id)
    }
}

// MARK: - Sidebar

private struct RemoteSessionSidebar: View {
    var model: RemoteHostModel

    var body: some View {
        List(selection: Binding(get: { model.selectedSessionID }, set: { model.selectSession($0) })) {
            if let message = model.error {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .onTapGesture { model.error = nil }
            }
            ForEach(model.liveSessionsByProject, id: \.project.id) { group in
                Section(group.project.name) {
                    ForEach(group.sessions) { session in
                        RemoteSessionRow(session: session, stopping: model.stopping.contains(session.id))
                            .tag(session.id)
                            .contextMenu {
                                if model.stopIsSupported && session.state.isLive {
                                    Button("Stop Session") { Task { await model.stop(session.id, force: false) } }
                                    Button("Force Stop Session") { Task { await model.stop(session.id, force: true) } }
                                }
                            }
                    }
                }
            }
        }
        .overlay {
            if model.inventory != nil && model.liveSessionsByProject.isEmpty {
                ContentUnavailableView("No Live Sessions", systemImage: "terminal", description: Text("Start one with New Session."))
            }
        }
    }
}

private struct RemoteSessionRow: View {
    let session: SessionSummary
    let stopping: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.title).lineLimit(1)
                if session.kind != .shell {
                    AgentBadge(label: session.kind.label, color: AgentBadge.color(named: session.kind.badgeColorName))
                }
            }
            HStack(spacing: 6) {
                if let branch = session.branch { Text(branch).lineLimit(1) }
                Spacer(minLength: 0)
                Text(stopping ? "Stopping…" : session.state.label)
                    .foregroundStyle(session.needsAttention ? .orange : .secondary)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Terminal

struct RemoteTerminalPane: View {
    var model: RemoteHostModel
    let session: SessionSummary

    private var controller: RemoteSessionController? { model.terminals[session.id] }
    private var state: TerminalSessionState { controller?.state ?? .idle }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.title).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text(session.state.label).font(.caption).foregroundStyle(session.needsAttention ? .orange : .secondary)
                if session.state.isLive {
                    switch state {
                    case .controlLost:
                        Button("Take Control") { Task { await model.takeControl(of: session.id) } }
                            .help("Take this terminal from the client that controls it")
                    case .disconnected, .idle:
                        Button("Reconnect") { Task { await model.retryTerminal(session.id) } }
                    case .attaching, .attached, .ended:
                        EmptyView()
                    }
                    if model.stopIsSupported {
                        Menu {
                            Button("Stop Session") { Task { await model.stop(session.id, force: false) } }
                            Button("Force Stop Session") { Task { await model.stop(session.id, force: true) } }
                        } label: {
                            Label("Stop", systemImage: "stop.circle")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(model.stopping.contains(session.id) || !model.isConnected)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
            if let message = bannerMessage {
                Text(message).font(.caption).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12))
            }
            if session.state.isLive {
                RemoteTerminalHost(adapter: model.adapter(for: session.id))
                    .overlay {
                        if case .attaching = state {
                            ProgressView("Connecting to terminal…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(nsColor: .textBackgroundColor))
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                ContentUnavailableView(session.state.label, systemImage: session.state == .failed ? "exclamationmark.triangle" : "terminal",
                                       description: Text(session.kind == .shell ? "The shell has exited." : "The agent has stopped."))
            }
        }
        .task(id: model.isConnected) { await model.refreshSelection() }
    }

    private var bannerMessage: String? {
        guard session.state.isLive else { return nil }
        switch state {
        case .controlLost(let message): return message
        case .disconnected(let message): return message
        case .ended(let reason): return "The terminal attachment ended (\(reason.rawValue))."
        case .idle, .attaching, .attached: return model.isConnected ? nil : model.connectionMessage
        }
    }
}

struct RemoteTerminalHost: NSViewRepresentable {
    let adapter: any TerminalEngineAdapter
    func makeNSView(context: Context) -> NSView { adapter.makeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// File ▸ Remote Servers: one item per paired server, then the window that pairs and manages them.
struct RemoteServersMenu: View {
    var store: RemoteHostStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Remote Servers") {
            ForEach(store.savedHosts) { host in
                Button(host.name) { openWindow(id: "remote-host", value: host.hostID) }
            }
            if !store.savedHosts.isEmpty { Divider() }
            Button("Manage Remote Servers…") { openWindow(id: "remote-servers") }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
