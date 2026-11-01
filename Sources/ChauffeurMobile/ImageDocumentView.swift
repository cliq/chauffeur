import SwiftUI
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient

/// Previews an image file from the Mac. Like the markdown reader, it checks for changes every 2 seconds
/// and swaps in the new image when the file is rewritten.
struct ImageDocumentView: View {
    var model: MobileAppModel
    let sessionID: UUID
    let path: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var loaded: Loaded?
    @State private var error: String?

    private struct Loaded {
        var content: DocumentChunk
        var image: UIImage
        var pixelSize: CGSize?
        /// The original bytes, written out so Share sends the full-resolution file.
        var fileURL: URL?
    }

    private var displayedPath: String { loaded?.content.path ?? path }
    private var fileName: String { URL(fileURLWithPath: displayedPath).lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            if !model.isConnected {
                Label("Disconnected · Last known image", systemImage: "wifi.slash")
                    .font(.caption).padding().frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.15))
            } else if let error, loaded != nil {
                Text("Last known image · \(error)").font(.caption).padding().foregroundStyle(.secondary)
            }
            if let loaded {
                ImagePreviewView(image: loaded.image)
                    .ignoresSafeArea(edges: .bottom)
                    .accessibilityIdentifier("image-preview")
                    .accessibilityLabel(fileName)
            } else if let error {
                ContentUnavailableView("Image unavailable", systemImage: "photo", description: Text(error))
            } else if model.isConnected {
                ProgressView("Loading image…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Not connected", systemImage: "wifi.slash", description: Text("Reconnect to your Mac to see this image."))
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let loaded {
                ToolbarItem(placement: .bottomBar) {
                    Text(details(loaded)).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("image-preview-details")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(!model.isConnected)
                        .accessibilityIdentifier("image-preview-refresh")
                    if let fileURL = loaded?.fileURL {
                        ShareLink(item: fileURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    if let image = loaded?.image {
                        Button("Copy Image", systemImage: "photo.on.rectangle") { UIPasteboard.general.image = image }
                    }
                    Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = displayedPath }
                }
            }
        }
        .onDisappear {
            // The share copy can be tens of megabytes; don't leave one behind per opened preview.
            if let fileURL = loaded?.fileURL { Self.removeShareFile(fileURL) }
            loaded = nil
        }
        .task(id: model.isConnected && scenePhase == .active) {
            guard model.isConnected, scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func details(_ loaded: Loaded) -> String {
        var parts = [String]()
        if let size = loaded.pixelSize { parts.append("\(Int(size.width)) × \(Int(size.height))") }
        parts.append(ByteCountFormatter.string(fromByteCount: loaded.content.size, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func refresh() async {
        guard let host = model.session else { return }
        do {
            let received = try await host.readDocumentData(sessionID: sessionID, path: path, knownVersion: loaded?.content.version)
            guard !Task.isCancelled else { return }
            if let data = received.data {
                let name = URL(fileURLWithPath: received.path).lastPathComponent
                let decoded = await Task.detached(priority: .userInitiated) { () -> (UIImage, CGSize?, URL?)? in
                    guard let image = ImageDecoding.image(from: data) else { return nil }
                    return (image, ImageDecoding.pixelSize(of: data), Self.writeShareFile(data, name: name))
                }.value
                guard !Task.isCancelled else {
                    if let fileURL = decoded?.2 { Self.removeShareFile(fileURL) }
                    return
                }
                guard let decoded else {
                    error = "This image format can’t be shown on this device."
                    return
                }
                if let old = loaded?.fileURL { Self.removeShareFile(old) }
                loaded = Loaded(content: received, image: decoded.0, pixelSize: decoded.1, fileURL: decoded.2)
            } else if var current = loaded {
                current.content = received
                loaded = current
            }
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = (error as? RemoteClientError)?.userMessage ?? error.localizedDescription
        }
    }

    private nonisolated static func removeShareFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Writes the original bytes to a fresh temporary folder, keeping the host file name, for the share sheet.
    private nonisolated static func writeShareFile(_ data: Data, name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagePreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name.isEmpty ? "image" : name)
            try data.write(to: url, options: .completeFileProtection)
            return url
        } catch { return nil }
    }
}
