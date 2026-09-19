import ChauffeurCore
import Foundation
import Testing
@testable import ChauffeurRuntimeKit

struct ConfigurationPublisherTests {
    private func fixture(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-publisher-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func values(root: URL) throws -> (FileStore, SetupAgentPair, CopyPreview, SetupOperation) {
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent(".codex-team")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("model = \"gpt-5\"".utf8).write(to: source.appendingPathComponent("config.toml"))
        let pair = SetupAgentPair(kind: .codex, choice: .create, sourcePath: source.path, destinationPath: destination.path, categories: [.preferences])
        let preview = try CodexConfigurationMigration().preview(pair: pair)
        let operation = SetupOperation(pairID: pair.id, destinationPath: destination.path, previewID: preview.id)
        let store = try FileStore(root: root.appendingPathComponent("store"))
        return (store, pair, preview, operation)
    }

    @Test func publicationIsNoReplaceAndIdempotent() async throws {
        let root = try fixture("success"); defer { try? FileManager.default.removeItem(at: root) }
        let (store, pair, preview, operation) = try values(root: root)
        let publisher = ConfigurationPublisher(store: store)
        let before = try Data(contentsOf: URL(fileURLWithPath: pair.sourcePath!).appendingPathComponent("config.toml"))
        let first = try await publisher.publish(operation: operation, preview: preview, pair: pair)
        let resumed = try await publisher.publish(operation: operation, preview: preview, pair: pair)
        #expect(resumed.destinationPath == first.destinationPath)
        #expect(resumed.operationID == first.operationID)
        #expect(first.files.keys.contains("config.toml"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: pair.sourcePath!).appendingPathComponent("config.toml")) == before)
    }

    @Test func existingDestinationIsPreserved() async throws {
        let root = try fixture("collision"); defer { try? FileManager.default.removeItem(at: root) }
        let (store, pair, preview, operation) = try values(root: root)
        let destination = URL(fileURLWithPath: pair.destinationPath)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let publisher = ConfigurationPublisher(store: store)
        await #expect(throws: ConfigurationMigrationError.self) { _ = try await publisher.publish(operation: operation, preview: preview, pair: pair) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "preserve")
    }

    @Test func retryRecoversPublicationAfterRenameInterruptionWithoutRecopying() async throws {
        let root = try fixture("recover"); defer { try? FileManager.default.removeItem(at: root) }
        let (store, pair, preview, operation) = try values(root: root)
        enum Stop: Error { case afterRename }
        let interrupted = ConfigurationPublisher(store: store) { point in if case .published = point { throw Stop.afterRename } }
        await #expect(throws: Stop.self) { _ = try await interrupted.publish(operation: operation, preview: preview, pair: pair) }
        let destinationFile = URL(fileURLWithPath: pair.destinationPath).appendingPathComponent("config.toml")
        try Data("model = \"user-edit\"".utf8).write(to: destinationFile)
        let recovered = try await ConfigurationPublisher(store: store).publish(operation: operation, preview: preview, pair: pair)
        #expect(recovered.operationID == operation.id)
        #expect(try String(contentsOf: destinationFile, encoding: .utf8).contains("user-edit"))
        let journal = try await store.setupOperations().first { $0.value.id == operation.id }
        #expect(journal?.value.phase == .published)
        #expect(journal?.value.message?.contains("preserved") == true)
    }

    @Test func destinationCreatedDuringStagingIsNeverReplaced() async throws {
        let root = try fixture("race"); defer { try? FileManager.default.removeItem(at: root) }
        let (store, pair, preview, operation) = try values(root: root)
        let destination = URL(fileURLWithPath: pair.destinationPath)
        let publisher = ConfigurationPublisher(store: store) { point in
            guard case .staged = point else { return }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data("concurrent writer".utf8).write(to: destination.appendingPathComponent("sentinel"))
        }
        await #expect(throws: ConfigurationMigrationError.self) {
            _ = try await publisher.publish(operation: operation, preview: preview, pair: pair)
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("sentinel"), encoding: .utf8) == "concurrent writer")
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
    }
}
