import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient
import ChauffeurTerminalInterface

/// Sends a photo or file to the Mac and pastes the path the Mac saved it at into the terminal,
/// so a screenshot can be handed to an agent.
struct FileUploadButton: View {
    var model: MobileAppModel
    let adapter: any TerminalEngineAdapter
    @State private var choosingPhoto = false
    @State private var choosingFile = false
    @State private var photo: PhotosPickerItem?
    @State private var progress: Double?
    @State private var failure: String?

    var body: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhoto = true }
                .accessibilityIdentifier("upload-photo")
            Button("Files", systemImage: "folder") { choosingFile = true }
                .accessibilityIdentifier("upload-file")
        } label: {
            Group {
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperclip")
                }
            }
            .font(.subheadline)
            .frame(minWidth: 20)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .disabled(progress != nil)
        .accessibilityLabel(progress == nil ? "Send photo or file" : "Sending file")
        .accessibilityIdentifier("key-upload")
        .photosPicker(isPresented: $choosingPhoto, selection: $photo, matching: .images)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): Task { await send { try Self.file(at: url) } }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await send { try await Self.photo(item) } }
        }
        .alert("Could not send the file", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func send(_ load: () async throws -> (data: Data, filename: String)) async {
        progress = 0
        defer { progress = nil }
        do {
            let file = try await load()
            let path = try await model.uploadFile(file.data, filename: file.filename) { progress = $0 }
            // A trailing space lets the next word follow the path directly.
            adapter.paste(path + " ")
            adapter.focus()
        } catch let error as RemoteClientError {
            failure = error.userMessage
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Screenshots arrive as PNG and keep their format; formats agents may not read, such as
    /// HEIC, are converted to JPEG.
    private static func photo(_ item: PhotosPickerItem) async throws -> (data: Data, filename: String) {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The photo could not be loaded."])
        }
        let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        if let type, type.conforms(to: .png) { return (data, "screenshot-\(stamp).png") }
        if let type, type.conforms(to: .jpeg) || type.conforms(to: .gif), let ext = type.preferredFilenameExtension { return (data, "photo-\(stamp).\(ext)") }
        guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The photo's format is not supported."])
        }
        return (jpeg, "photo-\(stamp).jpg")
    }

    private static func file(at url: URL) throws -> (data: Data, filename: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) > UploadFileChunkRequest.maxTotalBytes {
            throw CocoaError(.fileReadTooLarge, userInfo: [NSLocalizedDescriptionKey: "Files can be at most \(UploadFileChunkRequest.maxTotalBytes / 1_048_576) MB."])
        }
        return (try Data(contentsOf: url), url.lastPathComponent)
    }
}
