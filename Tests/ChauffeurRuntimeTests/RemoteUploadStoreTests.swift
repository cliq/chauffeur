import Foundation
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

struct RemoteUploadStoreTests {
    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/tmp/chauffeur-uploads-\(UUID())")
    }

    @Test func chunksAssembleIntoAPrivateFileNamedLikeTheOriginal() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteUploadStore(root: root)
        let device = UUID(), id = UUID()
        let bytes = Data((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0) })
        var offset = 0
        var status: UploadedFileStatus?
        while offset < bytes.count {
            let end = min(offset + UploadFileChunkRequest.chunkBytes, bytes.count)
            let chunk = UploadFileChunkRequest(uploadID: id, filename: "Screenshot 2026-10-01 at 10.00.png", totalBytes: Int64(bytes.count), offset: Int64(offset), data: bytes[offset..<end])
            status = try await store.receive(chunk, deviceID: device)
            #expect(status?.receivedBytes == Int64(end))
            #expect((status?.path == nil) == (end < bytes.count))
            // A retry of a chunk whose response was lost changes nothing.
            #expect(try await store.receive(chunk, deviceID: device).receivedBytes == Int64(end))
            offset = end
        }
        let path = try #require(status?.path)
        #expect(path.hasSuffix("/Screenshot-2026-10-01-at-10.00.png"))
        #expect(!path.contains(" "))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
        // Resending the finished upload returns the same file.
        let last = UploadFileChunkRequest(uploadID: id, filename: "Screenshot 2026-10-01 at 10.00.png", totalBytes: Int64(bytes.count), offset: 2 * Int64(UploadFileChunkRequest.chunkBytes), data: bytes[(2 * UploadFileChunkRequest.chunkBytes)...])
        #expect(try await store.receive(last, deviceID: device).path == path)
    }

    @Test func outOfOrderChunksAndOtherDevicesAreRefused() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteUploadStore(root: root)
        let device = UUID(), id = UUID()
        func chunk(_ offset: Int64, _ count: Int = 10) -> UploadFileChunkRequest {
            UploadFileChunkRequest(uploadID: id, filename: "notes.txt", totalBytes: 30, offset: offset, data: Data(repeating: 1, count: count))
        }
        func code(_ request: UploadFileChunkRequest, device: UUID) async -> String? {
            do { _ = try await store.receive(request, deviceID: device); return nil }
            catch let error as ChauffeurError { return error.code }
            catch { return "other" }
        }
        #expect(await code(chunk(10), device: device) == "upload_unknown")
        _ = try await store.receive(chunk(0), deviceID: device)
        #expect(await code(chunk(20), device: device) == "upload_offset")
        #expect(await code(chunk(10), device: UUID()) == "upload_conflict")
        #expect(await code(chunk(10, 25), device: device) == "upload_offset")
        #expect(try await store.receive(chunk(10), deviceID: device).receivedBytes == 20)
    }

    @Test func namesAndSizesAreValidated() async throws {
        #expect(try RemoteUploadStore.safeFilename("../../etc/passwd") == "passwd")
        #expect(try RemoteUploadStore.safeFilename("Café menu (1).HEIC") == "Caf-menu-1-.HEIC")
        #expect(throws: ChauffeurError.self) { try RemoteUploadStore.safeFilename("..") }
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteUploadStore(root: root)
        let tooLarge = UploadFileChunkRequest(uploadID: UUID(), filename: "big.bin", totalBytes: UploadFileChunkRequest.maxTotalBytes + 1, offset: 0, data: Data([1]))
        await #expect(throws: ChauffeurError.self) { _ = try await store.receive(tooLarge, deviceID: UUID()) }
        let empty = UploadFileChunkRequest(uploadID: UUID(), filename: "empty.txt", totalBytes: 1, offset: 0, data: Data())
        await #expect(throws: ChauffeurError.self) { _ = try await store.receive(empty, deviceID: UUID()) }
    }
}
