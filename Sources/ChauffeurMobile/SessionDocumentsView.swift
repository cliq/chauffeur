import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

struct SessionDocumentsView: View {
    var model: MobileAppModel
    let sessionID: UUID
    @State private var list: SessionDocumentList?
    @State private var error: String?

    var body: some View {
        Group {
            if let list {
                if list.documents.isEmpty {
                    ContentUnavailableView("No documents yet", systemImage: "doc.text",
                                           description: Text("Markdown files mentioned in or changed by this session appear here."))
                } else {
                    List(list.documents, id: \.path) { document in
                        Button {
                            model.path.append(.document(sessionID: sessionID, path: document.path))
                        } label: {
                            row(document)
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("documents-list")
                }
            } else if let error {
                ContentUnavailableView("Documents unavailable", systemImage: "doc.text", description: Text(error))
            } else if !model.isConnected {
                ContentUnavailableView("Not connected", systemImage: "wifi.slash", description: Text("Reconnect to your Mac to see this session’s documents."))
            } else {
                ProgressView("Loading documents…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Documents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(!model.isConnected)
            }
        }
        .refreshable { await refresh() }
        .task(id: model.isConnected) {
            guard model.isConnected else { return }
            await refresh()
        }
    }

    private func row(_ document: SessionDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(URL(fileURLWithPath: document.path).lastPathComponent).font(.headline)
            Text(document.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            HStack(spacing: 6) {
                Text(document.modifiedAt, format: .relative(presentation: .named))
                if document.sources.contains(.changed) { badge("Changed", .orange) }
                if document.sources.contains(.mentioned) { badge("Mentioned", .blue) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func badge(_ title: String, _ color: Color) -> some View {
        Text(title).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func refresh() async {
        guard let host = model.session else { return }
        do {
            let received = try await host.sessionDocuments(sessionID: sessionID)
            guard !Task.isCancelled else { return }
            list = received; error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? RemoteClientError)?.userMessage ?? error.localizedDescription
        }
    }
}
