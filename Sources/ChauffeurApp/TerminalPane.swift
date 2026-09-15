import SwiftUI
import AppKit
import ChauffeurCore
@preconcurrency import SwiftTerm

@MainActor final class TerminalController: ObservableObject, @preconcurrency TerminalViewDelegate {
    let sessionID: UUID
    let owner = UUID()
    let terminal = ThemedTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
    @Published var status: String?
    @Published var connected = false
    @Published var historyPresented = false
    private let readOnly: Bool
    var historyController: TerminalController?
    private var connection: SocketConnection?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var outgoing: AsyncStream<IPCRequest>.Continuation?
    private var generation = UUID()
    #if DEBUG
    var debugEvents: [String] = []
    private func trace(_ text: String) {
        debugEvents.append(text)
        if debugEvents.count > 40 { debugEvents.removeFirst(debugEvents.count - 40) }
    }
    #endif
    init(sessionID: UUID, scrollback: Int, readOnly: Bool = false) {
        self.sessionID = sessionID
        self.readOnly = readOnly
        terminal.terminalDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.getTerminal().changeScrollback(scrollback)
        terminal.applyAppearance()
        terminal.setAccessibilityIdentifier("terminal-\(sessionID.uuidString)")
    }
    func attach(socketPath: String) {
        guard !readOnly, reader == nil else { return }
        let current = UUID(); generation = current
        #if DEBUG
        trace("attach \(current)")
        #endif
        status = "Connecting…"
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                let socket = try SocketConnection(path: socketPath); connection = socket
                let size = terminal.getTerminal()
                let request = IPCRequest("attach", params: .object(["sessionID": .string(sessionID.uuidString), "owner": .string(owner.uuidString), "cols": .number(Double(max(2, min(500, size.cols)))), "rows": .number(Double(max(2, min(300, size.rows))))]))
                try await socket.sendAsync(request)
                let response = try await socket.receiveAsync(IPCResponse.self)
                guard generation == current, !Task.isCancelled else { socket.close(); return }
                if let error = response.error { throw error }
                guard response.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "Restart the service to match this app version") }
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
                terminal.feed(text: "\u{1b}c")
                // Layout may change while the attachment handshake is pending.
                let currentSize = terminal.getTerminal()
                sizeChanged(source: terminal, newCols: currentSize.cols, newRows: currentSize.rows)
                while !Task.isCancelled && generation == current {
                    let packet = try await socket.receiveAsync(TerminalPacket.self)
                    guard generation == current, !Task.isCancelled else { return }
                    guard packet.version == WireProtocol.major else { throw ChauffeurError("protocol_mismatch", "Terminal protocol changed") }
                    if packet.kind == "error" { throw ChauffeurError("terminal_error", packet.message ?? "Terminal disconnected") }
                    if let bytes = packet.bytes {
                        terminal.feed(byteArray: Array(bytes)[...]); connected = true; status = nil
                    }
                }
            } catch {
                if generation == current { status = (error as? ChauffeurError)?.message ?? "Terminal disconnected. Reconnect to the live session"; connected = false }
            }
            if generation == current { connection?.close(); outgoing?.finish(); writer?.cancel(); reader = nil }
        }
    }
    func detach() {
        #if DEBUG
        if reader != nil { trace("detach \(generation)") }
        #endif
        generation = UUID(); outgoing?.finish(); writer?.cancel(); reader?.cancel()
        connection?.close(); connection = nil; reader = nil; writer = nil; outgoing = nil; connected = false
    }
    func focus() { terminal.window?.makeFirstResponder(terminal) }
    func find() {
        if readOnly { terminal.performTextFinderAction(findSender()) }
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
        terminal.getTerminal().changeScrollback(snapshot.lineLimit + snapshot.rows)
        terminal.feed(text: "\u{1b}c" + snapshot.rendering)
    }
    private func findSender() -> NSMenuItem { let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue; return item }
    private func enqueue(_ request: IPCRequest) {
        guard !readOnly else { return }
        let result = outgoing?.yield(request)
        #if DEBUG
        trace("queue \(request.method) \(request.params["cols"].int ?? 0)x\(request.params["rows"].int ?? 0): active=\(outgoing != nil)")
        #endif
        if case .dropped = result { status = "Terminal input queue is full. Reconnect before continuing"; connection?.close() }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { enqueue(IPCRequest("input", params: .object(["bytes": .string(Data(data).base64EncodedString())]))) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols >= 2 && newRows >= 2 else { return }
        enqueue(IPCRequest("resize", params: .object(["cols": .number(Double(min(newCols, 500))), "rows": .number(Double(min(newRows, 300)))])))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) { NSSound.beep() }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct TerminalHost: NSViewRepresentable {
    @ObservedObject var controller: TerminalController
    func makeNSView(context: Context) -> TerminalView { controller.terminal }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
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
                if !controller.connected && session.state.isLive {
                    Button("Reconnect") { controller.detach(); controller.attach(socketPath: model.socketPath) }
                }
            }.padding(.horizontal, 12).padding(.vertical, 7).background(.bar)
            if let status = controller.status, !controller.connected { Text(status).font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.12)) }
            if session.state.isLive {
                TerminalHost(controller: controller)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: session.state == .failed ? "exclamationmark.triangle" : "terminal").font(.largeTitle)
                    Text(session.state.label).font(.title2)
                    Text(session.error ?? "The agent has stopped. Open History to view saved terminal output.").foregroundStyle(.secondary).multilineTextAlignment(.center)
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
