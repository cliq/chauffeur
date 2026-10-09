import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

struct DocumentReaderView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case rendered = "Rendered"
        case source = "Source"
        var id: String { rawValue }
    }

    var model: MobileAppModel
    let sessionID: UUID
    let path: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var content: DocumentContent?
    @State private var text: String?
    @State private var mode: Mode = .rendered
    @State private var error: String?

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]

    private var displayedPath: String { content?.path ?? path }
    private var isMarkdown: Bool {
        Self.markdownExtensions.contains(URL(fileURLWithPath: displayedPath).pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.isConnected {
                Label("Disconnected · Last known content", systemImage: "wifi.slash")
                    .font(.caption).padding().frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.15))
            } else if let error, text != nil {
                Text("Last known content · \(error)").font(.caption).padding().foregroundStyle(.secondary)
            }
            if let text {
                if isMarkdown, mode == .rendered {
                    ReaderHTMLView(markdown: text, onOpenLink: openLink)
                        .accessibilityIdentifier("document-reader")
                } else {
                    DocumentSourceView(text: text)
                        .accessibilityIdentifier("document-reader")
                }
            } else if let error {
                ContentUnavailableView("Document unavailable", systemImage: "doc.text", description: Text(error))
            } else if model.isConnected {
                ProgressView("Loading document…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Not connected", systemImage: "wifi.slash", description: Text("Reconnect to your Mac to read this document."))
            }
        }
        .navigationTitle(URL(fileURLWithPath: displayedPath).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isMarkdown {
                // The bottom bar keeps the navigation title free for the file name.
                ToolbarItem(placement: .bottomBar) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    .accessibilityIdentifier("document-reader-mode")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(!model.isConnected)
                        .accessibilityIdentifier("document-reader-refresh")
                    if let text {
                        ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = displayedPath }
                }
            }
        }
        .task(id: model.isConnected && scenePhase == .active) {
            guard model.isConnected, scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func openLink(_ href: String) {
        switch DocumentLinkResolver.resolve(href, relativeTo: displayedPath) {
        case .web(let url): UIApplication.shared.open(url)
        case .document(let target): model.path.append(.document(sessionID: sessionID, path: target))
        case nil: break
        }
    }

    private func refresh() async {
        guard let host = model.session else { return }
        do {
            let received = try await host.readDocument(sessionID: sessionID, path: path, knownVersion: content?.version)
            guard !Task.isCancelled else { return }
            if let newText = received.text { text = newText }
            if text != nil || received.text != nil { content = received }
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? RemoteClientError)?.userMessage ?? error.localizedDescription
        }
    }
}
