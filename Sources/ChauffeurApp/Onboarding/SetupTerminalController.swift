import SwiftUI
import AppKit
import ChauffeurCore
import ChauffeurTerminalInterface
import ChauffeurTerminalSwiftTerm

@MainActor final class SetupTerminalController: ObservableObject, TerminalEngineAdapterDelegate {
    let adapter: SwiftTermAdapter
    @Published var error: String?
    private let app: AppModel
    private var handle: SetupLoginHandle
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var outgoing: AsyncStream<Data>.Continuation?
    private var cursor: UInt64 = 0
    init(app: AppModel, handle: SetupLoginHandle) {
        self.app = app; self.handle = handle
        adapter = SwiftTermAdapter(appearance: TerminalAppearance(fontSize: 12, scrollbackLines: 1000, followsSystemColors: true))
        adapter.delegate = self
        adapter.setInputEnabled(false)
    }
    private var params: [String: JSONValue] {
        ["operationID": .string(handle.operationID.uuidString), "generation": .number(Double(handle.generation))]
    }
    func start() {
        guard reader == nil else { return }
        let stream = AsyncStream<Data> { outgoing = $0 }
        writer = Task { [weak self] in
            for await data in stream {
                guard let self, !Task.isCancelled, self.adapter.isInputEnabled else { return }
                do {
                    var values = self.params; values["bytes"] = .string(data.base64EncodedString())
                    _ = try await self.app.call("inputSetupLogin", .object(values))
                } catch { self.fail(error); return }
            }
        }
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                // Explicit takeover keeps reopened views usable and revokes stale input.
                self.handle = try await self.app.call("attachSetupLogin", .object([
                    "operationID": .string(self.handle.operationID.uuidString), "takeControl": .bool(true)
                ])).decode(SetupLoginHandle.self)
                self.adapter.setInputEnabled(true)
                while !Task.isCancelled {
                    var values = self.params; values["cursor"] = .number(Double(self.cursor))
                    let output = try await self.app.call("readSetupLogin", .object(values)).decode(SetupLoginOutput.self)
                    if self.cursor < output.oldestCursor { self.adapter.reset() }
                    if !output.bytes.isEmpty { self.adapter.feed(output.bytes) }
                    self.cursor = output.nextCursor
                    if !output.running { self.adapter.setInputEnabled(false); return }
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch is CancellationError {} catch { self.fail(error) }
        }
    }
    func stop() {
        reader?.cancel(); reader = nil; outgoing?.finish(); writer?.cancel(); writer = nil
        adapter.setInputEnabled(false)
        let app = app, values = params
        Task { _ = try? await app.call("detachSetupLogin", .object(values)) }
    }
    private func fail(_ failure: Error) { adapter.setInputEnabled(false); outgoing?.finish(); error = failure.localizedDescription }
    func terminal(_ adapter: any TerminalEngineAdapter, didGenerateInput data: Data) {
        guard adapter.isInputEnabled else { return }; outgoing?.yield(data)
    }
    func terminal(_ adapter: any TerminalEngineAdapter, didChangeCellSize size: TerminalCellSize) {
        guard adapter.isInputEnabled else { return }
        var values = params; values["cols"] = .number(Double(size.cols)); values["rows"] = .number(Double(size.rows))
        Task { _ = try? await app.call("resizeSetupLogin", .object(values)) }
    }
    func terminal(_ adapter: any TerminalEngineAdapter, didCopyToClipboard text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func terminal(_ adapter: any TerminalEngineAdapter, didRequestOpenLink link: String) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct SetupTerminalView: View {
    @StateObject private var controller: SetupTerminalController
    init(app: AppModel, handle: SetupLoginHandle) { _controller = StateObject(wrappedValue: SetupTerminalController(app: app, handle: handle)) }
    var body: some View {
        VStack(spacing: 3) {
            SetupTerminalHost(controller: controller)
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.onAppear { controller.start() }.onDisappear { controller.stop() }
    }
}

private struct SetupTerminalHost: NSViewRepresentable {
    let controller: SetupTerminalController
    func makeNSView(context: Context) -> NSView { controller.adapter.makeView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
