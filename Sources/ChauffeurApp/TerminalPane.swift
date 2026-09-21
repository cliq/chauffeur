import SwiftUI
import AppKit
import ChauffeurCore
import ChauffeurTerminalInterface
import ChauffeurTerminalSwiftTerm

/// Whether this view controls the session's terminal. A terminal whose control
/// was taken by another client stays `controlLost` until the user takes it
/// back; automatic reattachment must never reclaim it silently.
enum TerminalControlState: Equatable { case detached, connecting, connected, controlLost(String), failed(String) }

/// Owns one session's IPC attachment (connection, attachment generation, control
/// state, outgoing queue) and drives an engine-neutral `TerminalEngineAdapter`.
/// Every byte in or out crosses the adapter; the controller never talks to
/// SwiftTerm for I/O. Engine-specific desktop features (history find, focus
/// deferral, accessibility, the Debug probe) reach the themed view through
/// `desktopAdapter`/`terminal` only.
@MainActor final class TerminalController: ObservableObject, TerminalEngineAdapterDelegate {
    let sessionID: UUID
    /// The engine-neutral terminal this controller feeds and listens to.
    let adapter: any TerminalEngineAdapter
    /// The same object as `adapter` when it is the production SwiftTerm adapter;
    /// `nil` when a test or probe injected another engine.
    let desktopAdapter: SwiftTermAdapter?
    @Published var status: String?
    @Published var connected = false
    @Published var controlState: TerminalControlState = .detached { didSet { syncInputGate() } }
    @Published var historyPresented = false
    private let readOnly: Bool
    var historyController: TerminalController?
    private var connection: SocketConnection?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryAttempt = 0
    private var outgoing: AsyncStream<IPCRequest>.Continuation?
    private var generation = UUID()
    /// The runtime's identity for the current attachment; every input and
    /// resize command carries it so a superseded view cannot act on the terminal.
    private var attachmentGeneration: UInt64? { didSet { syncInputGate() } }
    #if DEBUG
    var debugEvents: [String] = []
    func simulateConnectionDrop() { connection?.close() }
    private func trace(_ text: String) {
        debugEvents.append(text)
        if debugEvents.count > 40 { debugEvents.removeFirst(debugEvents.count - 40) }
    }
    #endif
    /// Creates the controller around the desktop SwiftTerm adapter wrapping the
    /// app's themed view, unless `adapter` injects another engine (probes, tests).
    init(sessionID: UUID, scrollback: Int, readOnly: Bool = false, adapter: (any TerminalEngineAdapter)? = nil) {
        self.sessionID = sessionID
        self.readOnly = readOnly
        // `ThemedTerminalView` owns the colors (it re-applies them on appearance
        // changes), so the adapter is told not to touch them.
        let appearance = TerminalAppearance(fontSize: 13, scrollbackLines: scrollback, followsSystemColors: false)
        let engine: any TerminalEngineAdapter = adapter ?? SwiftTermAdapter(view: ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 620)), appearance: appearance)
        self.adapter = engine
        self.desktopAdapter = engine as? SwiftTermAdapter
        engine.delegate = self
        if let view = themedView {
            view.acceptsFileDrops = !readOnly
            view.applyAppearance()
            view.setAccessibilityIdentifier("\(readOnly ? "history" : "terminal")-\(sessionID.uuidString)")
            view.setAccessibilityLabel(readOnly ? "Saved terminal history" : "Agent terminal")
            // Drops go through the adapter so the input gate and the bracketed
            // paste encoding are the engine's, not the view's.
            view.pasteHandler = { [weak self] text in self?.adapter.paste(text) }
        }
        #if DEBUG
        assert(TerminalAdapterConformance.check(engine).isEmpty, "Terminal adapter violates its contract: \(TerminalAdapterConformance.check(engine))")
        #endif
        syncInputGate()
    }
    /// The desktop's themed SwiftTerm view, when the production adapter is in
    /// use. Only for engine-specific desktop features (focus deferral, find, the
    /// Debug probe); never for bytes.
    private var themedView: ThemedTerminalView? { desktopAdapter?.view as? ThemedTerminalView }
    /// The themed view for callers that only exist on the desktop (`ProjectWindow`
    /// focus checks, `NativeProbe`). Traps when another engine was injected.
    var terminal: ThemedTerminalView {
        guard let themedView else { preconditionFailure("TerminalController.terminal requires the SwiftTerm desktop adapter") }
        return themedView
    }
    /// Input may leave the terminal only while this controller holds a live
    /// attachment it controls. Anything typed otherwise is dropped by the
    /// adapter, never queued, so nothing replays after a reconnect.
    private func syncInputGate() {
        let enabled = !readOnly && attachmentGeneration != nil && controlState == .connected
        if adapter.isInputEnabled != enabled { adapter.setInputEnabled(enabled) }
        themedView?.inputEnabled = enabled
    }
    /// Attaches to the live terminal. Automatic calls (layout synchronization)
    /// leave a terminal alone once another client took control of it; only an
    /// explicit `takeControl` reclaims it.
    func attach(socketPath: String, takeControl: Bool = false) {
        guard !readOnly, reader == nil, retry == nil else { return }
        if case .controlLost = controlState, !takeControl { return }
        let current = UUID(); generation = current
        #if DEBUG
        trace("attach \(current) takeControl=\(takeControl)")
        #endif
        status = "Connecting…"; controlState = .connecting
        reader = Task { [weak self] in
            guard let self, generation == current, !Task.isCancelled else { return }
            var shouldRetry = false
            do {
                let socket = try SocketConnection(path: socketPath); connection = socket
                let size = adapter.cellSize
                let request = IPCRequest("attach", params: .object(["sessionID": .string(sessionID.uuidString), "cols": .number(Double(max(2, min(500, size.cols)))), "rows": .number(Double(max(2, min(300, size.rows)))), "takeControl": .bool(takeControl)]))
                try await socket.sendAsync(request)
                let response = try await socket.receiveAsync(IPCResponse.self)
                guard generation == current, !Task.isCancelled else { socket.close(); return }
                if let error = response.error { throw error }
                guard response.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "Restart the service to match this app version") }
                guard let granted = response.result?["generation"].int, granted >= 0 else { throw ChauffeurError("protocol_mismatch", "Service did not identify the terminal attachment. Restart the service") }
                let (stream, continuation) = AsyncStream<IPCRequest>.makeStream(bufferingPolicy: .bufferingOldest(512))
                outgoing = continuation
                writer = Task {
                    do {
                        for await packet in stream {
                            try await socket.sendAsync(packet)
                            #if DEBUG
                            trace("sent \(packet.method) \(packet.params["cols"].int ?? 0)x\(packet.params["rows"].int ?? 0)")
                            #endif
                        }
                        #if DEBUG
                        trace("writer ended \(current) cancelled=\(Task.isCancelled)")
                        #endif
                    }
                    catch { socket.close() }
                }
                attachmentGeneration = UInt64(granted); controlState = .connected
                adapter.reset()
                // Layout may change while the attachment handshake is pending.
                sendResize(adapter.cellSize)
                while !Task.isCancelled && generation == current {
                    let packet = try await socket.receiveAsync(TerminalPacket.self)
                    guard generation == current, !Task.isCancelled else { return }
                    guard packet.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "Terminal protocol changed") }
                    if packet.kind == "controlLost" {
                        loseControl(packet.message ?? "Another client took control of this terminal"); break
                    }
                    if packet.kind == "error" { throw ChauffeurError("terminal_error", packet.message ?? "Terminal disconnected") }
                    if let bytes = packet.bytes {
                        adapter.feed(bytes); connected = true; status = nil; retryAttempt = 0
                    }
                }
            } catch {
                if generation == current {
                    let failure = error as? ChauffeurError
                    if failure?.code == "terminal_busy" {
                        loseControl(failure?.message ?? "Another client took control of this terminal")
                    } else {
                        status = failure?.message ?? "Terminal disconnected. Reconnect to the live session"; connected = false
                        controlState = .failed(status ?? "Terminal disconnected")
                        shouldRetry = failure?.code != "protocol_mismatch" && failure?.code != "not_live"
                    }
                }
            }
            if generation == current {
                connection?.close(); connection = nil; outgoing?.finish(); outgoing = nil
                writer?.cancel(); writer = nil; reader = nil; attachmentGeneration = nil
                if shouldRetry { scheduleRetry(socketPath: socketPath, generation: current) }
            }
        }
    }
    /// Retry only while this tab remains attached. In particular, a retry never
    /// carries takeControl forward or replays input queued before a disconnect.
    private func scheduleRetry(socketPath: String, generation current: UUID) {
        let delay = min(0.25 * pow(2, Double(min(retryAttempt, 5))), 5)
        retryAttempt += 1
        status = "Reconnecting…"; controlState = .connecting
        retry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, generation == current, !Task.isCancelled else { return }
            retry = nil
            attach(socketPath: socketPath)
        }
    }
    /// Another client owns the terminal now. No "disconnected" status: the user
    /// chooses whether to take it back.
    private func loseControl(_ message: String) {
        #if DEBUG
        trace("control lost \(generation)")
        #endif
        controlState = .controlLost(message); connected = false; status = nil
    }
    func detach() {
        #if DEBUG
        if reader != nil { trace("detach \(generation)") }
        #endif
        generation = UUID(); retry?.cancel(); retry = nil; retryAttempt = 0
        outgoing?.finish(); writer?.cancel(); reader?.cancel()
        connection?.close(); connection = nil; reader = nil; writer = nil; outgoing = nil; connected = false; attachmentGeneration = nil
        // Lost control survives a detach so the next automatic attach still
        // leaves the terminal with the client that took it.
        if case .controlLost = controlState {} else { controlState = .detached }
    }
    /// Focuses the terminal, or arranges for it once the view is on screen: a
    /// newly selected tab is not in the window yet when its selection changes.
    func focus() {
        guard !readOnly else { return }
        if let themedView, themedView.window == nil { themedView.focusesWhenAttached = true } else { adapter.focus() }
    }
    func find() {
        if readOnly { desktopAdapter?.view.performTextFinderAction(findSender()) }
        else if historyPresented, let historyController { historyController.find() }
        else {
            historyController = TerminalController(sessionID: sessionID, scrollback: 10_000, readOnly: true)
            historyPresented = true
        }
    }
    func display(_ snapshot: TerminalSnapshot) {
        guard readOnly else { return }
        #if DEBUG
        trace("display history bytes=\(snapshot.history.utf8.count) screen bytes=\(snapshot.screen.utf8.count)")
        #endif
        adapter.configure(TerminalAppearance(fontSize: 13, scrollbackLines: snapshot.lineLimit + snapshot.rows, followsSystemColors: false))
        adapter.reset()
        adapter.feed(Data(snapshot.rendering.utf8))
    }
    private func findSender() -> NSMenuItem { let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue; return item }
    private func enqueue(_ request: IPCRequest) {
        guard !readOnly, let attachmentGeneration else { return }
        var request = request
        if case .object(var params) = request.params {
            params["generation"] = .number(Double(attachmentGeneration)); request.params = .object(params)
        }
        let result = outgoing?.yield(request)
        #if DEBUG
        trace("queue \(request.method) \(request.params["cols"].int ?? 0)x\(request.params["rows"].int ?? 0): active=\(outgoing != nil)")
        #endif
        if case .dropped = result { status = "Terminal input queue is full. Reconnect before continuing"; connection?.close() }
    }
    private func sendResize(_ size: TerminalCellSize) {
        guard size.cols >= 2 && size.rows >= 2 else { return }
        enqueue(IPCRequest("resize", params: .object(["cols": .number(Double(min(size.cols, 500))), "rows": .number(Double(min(size.rows, 300)))])))
    }

    // MARK: TerminalEngineAdapterDelegate

    func terminal(_ adapter: any TerminalEngineAdapter, didGenerateInput data: Data) {
        enqueue(IPCRequest("input", params: .object(["bytes": .string(data.base64EncodedString())])))
    }
    func terminal(_ adapter: any TerminalEngineAdapter, didChangeCellSize size: TerminalCellSize) { sendResize(size) }
    func terminal(_ adapter: any TerminalEngineAdapter, didChangeTitle title: String) {}
    func terminalDidRingBell(_ adapter: any TerminalEngineAdapter) { NSSound.beep() }
    /// OSC 52: the adapter only reports the request; writing the pasteboard is the app's call.
    func terminal(_ adapter: any TerminalEngineAdapter, didCopyToClipboard text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    /// The adapter already filters to web and mail links; the desktop additionally
    /// keeps its historical allowance for `file` URLs.
    func terminal(_ adapter: any TerminalEngineAdapter, didRequestOpenLink link: String) {
        guard let url = URL(string: link), ["http", "https", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct TerminalHost: NSViewRepresentable {
    @ObservedObject var controller: TerminalController
    func makeNSView(context: Context) -> NSView { controller.adapter.makeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct TerminalPane: View {
    @EnvironmentObject private var model: AppModel
    let session: Session
    @ObservedObject var controller: TerminalController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.title).fontWeight(.medium).lineLimit(1).help(session.title)
                Spacer()
                Text(session.state.label).font(.caption).foregroundStyle(session.needsAttention ? .orange : .secondary)
                Button { controller.find() } label: { Label("History and Search", systemImage: "clock.arrow.circlepath") }.labelStyle(.iconOnly).help("View and search saved terminal history")
                if case .controlLost = controller.controlState, session.state.isLive {
                    Button("Take Control") { controller.detach(); controller.attach(socketPath: model.socketPath, takeControl: true) }
                        .help("Take this terminal back from the client that controls it")
                } else if !controller.connected && controller.controlState != .connecting && session.state.isLive {
                    Button("Reconnect") { controller.detach(); controller.attach(socketPath: model.socketPath) }
                }
            }.padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
            if case .controlLost(let message) = controller.controlState, session.state.isLive {
                Text(message).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12))
            } else if let status = controller.status, !controller.connected { Text(status).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12)) }
            if session.state.isLive {
                TerminalHost(controller: controller)
                    .overlay {
                        if !controller.connected && (controller.controlState == .connecting || controller.controlState == .detached || controller.controlState == .connected) {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Connecting to terminal…").foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(nsColor: .textBackgroundColor))
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: session.state == .failed ? "exclamationmark.triangle" : "terminal").font(.largeTitle)
                    Text(session.state.label).font(.title2)
                    Text(session.error ?? (session.launch.preset.kind.isAgent ? "The agent has stopped. Open History to view saved terminal output." : "The shell has exited. Open History to view saved terminal output.")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Open History", systemImage: "clock.arrow.circlepath") { controller.find() }
                    if session.nativeConversationID != nil {
                        Button("Resume Conversation") { model.perform { _ = try await model.call("resume", .object(["sessionID": .string(session.id.uuidString)])) } }.buttonStyle(.borderedProminent)
                    }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .textBackgroundColor))
            .sheet(isPresented: $controller.historyPresented, onDismiss: { if !controller.historyPresented { controller.historyController = nil } }) {
                if let history = controller.historyController { TerminalHistoryView(session: session, controller: history).environmentObject(model) }
            }
    }
}

private struct TerminalHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @ObservedObject var controller: TerminalController
    @State private var snapshot: TerminalSnapshot?
    @State private var failure: String?
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Terminal History — \(session.title)").font(.headline)
                Spacer()
                Button("Refresh") { Task { await refresh() } }.disabled(loading)
                Button("Find") { controller.find() }.disabled(snapshot == nil).keyboardShortcut("f", modifiers: .command)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let snapshot {
                Text("Read-only capture from \(snapshot.capturedAt.formatted(date: .abbreviated, time: .standard)). \(snapshot.truncated ? "Older output was trimmed to the retention limits." : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
            if loading { ProgressView().controlSize(.small) }
            TerminalHost(controller: controller).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding().frame(minWidth: 720, idealWidth: 980, minHeight: 480, idealHeight: 680)
            .task { await refresh(); if snapshot != nil { controller.find() } }
    }
    private func refresh() async {
        loading = true; failure = nil; defer { loading = false }
        controller.status = "Loading saved terminal history…"
        do {
            let result = try await model.call("terminalSnapshot", .object(["sessionID": .string(session.id.uuidString)]))
            let saved = try await Task.detached { try result.decode(TerminalSnapshot.self) }.value
            try saved.validate(); snapshot = saved; controller.display(saved); controller.status = nil
        } catch { failure = (error as? ChauffeurError)?.message ?? "Could not load saved terminal history"; controller.status = failure }
    }
}
