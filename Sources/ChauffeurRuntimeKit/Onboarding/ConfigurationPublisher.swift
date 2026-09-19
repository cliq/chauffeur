import ChauffeurCore
import Darwin
import Foundation

public actor ConfigurationPublisher {
    public enum InterruptionPoint: Sendable {
        case journaled, staged, published, receiptSaved
    }

    public typealias InterruptionHook = @Sendable (InterruptionPoint) throws -> Void

    private struct OwnershipMarker: Codable, Equatable {
        var operationID: UUID
        var pairID: UUID
        var previewID: UUID
        var selectionDigest: String
        var complete: Bool
    }

    private static let markerName = ".chauffeur-onboarding-operation.json"
    private let store: FileStore
    private let migrations: [CLIKind: any ConfigurationMigration]
    private let interruptionHook: InterruptionHook?

    public init(
        store: FileStore,
        migrations: [CLIKind: any ConfigurationMigration] = [
            .claude: ClaudeConfigurationMigration(),
            .codex: CodexConfigurationMigration()
        ],
        interruptionHook: InterruptionHook? = nil
    ) {
        self.store = store
        self.migrations = migrations
        self.interruptionHook = interruptionHook
    }

    public func publish(operation supplied: SetupOperation, preview: CopyPreview, pair: SetupAgentPair) async throws -> CopyReceipt {
        let pairDestination = Paths.canonical(pair.destinationPath)
        guard supplied.pairID == pair.id, preview.pairID == pair.id,
              Paths.canonical(supplied.destinationPath) == pairDestination,
              Paths.canonical(preview.destinationPath) == pairDestination else {
            throw ConfigurationMigrationError.invalidPair("The copy operation no longer matches this team configuration.")
        }
        guard supplied.previewID == nil || supplied.previewID == preview.id else {
            throw ConfigurationMigrationError.sourceChanged("The reviewed preview changed before publication.")
        }
        guard let migration = migrations[pair.kind] else {
            throw ConfigurationMigrationError.invalidPair("No configuration migration adapter is available for \(pair.kind.rawValue).")
        }

        let destination = URL(fileURLWithPath: pair.destinationPath).standardizedFileURL
        try validateDestination(destination)
        let journal = try await store.setupOperations().first { $0.value.id == supplied.id }
        var operation = journal?.value ?? supplied

        if FileManager.default.fileExists(atPath: destination.path) {
            return try await receiptForPublishedDestination(operation: operation, preview: preview, pair: pair, destination: destination)
        }

        let stage = operation.stagingPath.map { URL(fileURLWithPath: $0) }
            ?? destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).chauffeur-stage-\(operation.id.uuidString)", isDirectory: true)
        guard stage.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            throw ConfigurationMigrationError.unsafePath("The staging folder must be beside the destination.")
        }
        operation.destinationPath = destination.path
        operation.stagingPath = stage.path
        operation.previewID = preview.id
        operation.phase = .prepared
        operation.message = nil
        var stored = try await save(operation)
        try interruptionHook?(.journaled)

        let completeMarker = OwnershipMarker(operationID: operation.id, pairID: pair.id, previewID: preview.id, selectionDigest: preview.selectionDigest, complete: true)
        let incompleteMarker = OwnershipMarker(operationID: operation.id, pairID: pair.id, previewID: preview.id, selectionDigest: preview.selectionDigest, complete: false)
        var needsWriting = true
        if FileManager.default.fileExists(atPath: stage.path) {
            if try marker(at: stage) == completeMarker {
                operation.files = try fileDigests(in: stage)
                operation.phase = .staged
                needsWriting = false
            } else if try marker(at: stage) == incompleteMarker {
                try removeOwnedStaging(stage, operationID: operation.id)
            } else {
                throw ConfigurationMigrationError.unsafePath("The staging path already exists and is not owned by this copy operation.")
            }
        }
        if needsWriting {
            guard Darwin.mkdir(stage.path, 0o700) == 0 else {
                throw ConfigurationMigrationError.unsafePath("Cannot create the private staging folder.")
            }
            do {
                try writeMarker(incompleteMarker, at: stage)
                try migration.write(preview: preview, pair: pair, staging: stage)
                try writeMarker(completeMarker, at: stage, replace: true)
                operation.files = try fileDigests(in: stage)
                operation.phase = .staged
                stored = try await store.saveSetupOperation(operation, expectedVersion: stored.version)
            } catch {
                try? removeOwnedStaging(stage, operationID: operation.id)
                throw error
            }
        }
        try interruptionHook?(.staged)

        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST, FileManager.default.fileExists(atPath: destination.path) {
                return try await receiptForPublishedDestination(operation: operation, preview: preview, pair: pair, destination: destination)
            }
            throw ConfigurationMigrationError.unsafePath("The destination changed or could not be published. Existing contents were preserved.")
        }
        try interruptionHook?(.published)

        operation.phase = .published
        operation.stagingPath = nil
        operation.files = try fileDigests(in: destination)
        stored = try await store.saveSetupOperation(operation, expectedVersion: stored.version)
        try interruptionHook?(.receiptSaved)
        return CopyReceipt(operationID: operation.id, destinationPath: destination.path, files: operation.files)
    }

    public func recover(operation supplied: SetupOperation) async throws -> SetupOperation {
        var operation = supplied
        let destination = URL(fileURLWithPath: operation.destinationPath).standardizedFileURL
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let marker = try marker(at: destination), marker.operationID == operation.id, marker.complete else {
                operation.phase = .failed
                operation.message = "The destination exists but belongs to another operation. It was preserved."
                return operation
            }
            let actual = try fileDigests(in: destination)
            let changed = operation.files.compactMap { path, digest in actual[path] == digest ? nil : path }.sorted()
            operation.phase = .published
            operation.stagingPath = nil
            operation.previewID = marker.previewID
            if !changed.isEmpty { operation.message = "Published files changed after setup and were preserved: \(changed.joined(separator: ", "))." }
            return operation
        }
        if let stagingPath = operation.stagingPath {
            let stage = URL(fileURLWithPath: stagingPath).standardizedFileURL
            if FileManager.default.fileExists(atPath: stage.path) {
                guard let marker = try marker(at: stage), marker.operationID == operation.id else {
                    operation.phase = .failed
                    operation.message = "The staging folder is no longer owned by this operation. It was preserved."
                    return operation
                }
                guard marker.complete else {
                    operation.phase = .prepared
                    operation.message = "Copy staging was interrupted and will be rebuilt on retry."
                    return operation
                }
                operation.phase = .staged
                operation.files = try fileDigests(in: stage)
                return operation
            }
        }
        operation.phase = .prepared
        operation.message = "Copy preparation was interrupted and can be retried."
        return operation
    }

    /// Removes only an unpublished staging folder whose ownership marker matches the operation.
    public func discardStaging(operation: SetupOperation) throws {
        guard operation.phase != .published, let path = operation.stagingPath else { return }
        try removeOwnedStaging(URL(fileURLWithPath: path), operationID: operation.id)
    }

    private func receiptForPublishedDestination(
        operation supplied: SetupOperation, preview: CopyPreview, pair: SetupAgentPair, destination: URL
    ) async throws -> CopyReceipt {
        let expected = OwnershipMarker(operationID: supplied.id, pairID: pair.id, previewID: preview.id, selectionDigest: preview.selectionDigest, complete: true)
        guard try marker(at: destination) == expected else {
            throw ConfigurationMigrationError.unsafePath("The destination already exists. Use that folder or choose another destination; setup will not merge or replace it.")
        }
        var operation = supplied
        let actual = try fileDigests(in: destination)
        let changed = operation.files.compactMap { path, digest in actual[path] == digest ? nil : path }.sorted()
        operation.destinationPath = destination.path
        operation.stagingPath = nil
        operation.previewID = preview.id
        operation.phase = .published
        if operation.files.isEmpty { operation.files = actual }
        if !changed.isEmpty { operation.message = "Published files changed after setup and were preserved: \(changed.joined(separator: ", "))." }
        _ = try await save(operation)
        return CopyReceipt(operationID: operation.id, destinationPath: destination.path, files: operation.files)
    }

    private func save(_ operation: SetupOperation) async throws -> Stored<SetupOperation> {
        let existing = try await store.setupOperations().first { $0.value.id == operation.id }
        return try await store.saveSetupOperation(operation, expectedVersion: existing?.version)
    }

    private func validateDestination(_ destination: URL) throws {
        guard destination.path.hasPrefix("/"), destination.lastPathComponent != ".", destination.lastPathComponent != ".." else {
            throw ConfigurationMigrationError.unsafePath("Choose an absolute destination folder.")
        }
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: parent.path) else {
            throw ConfigurationMigrationError.unsafePath("The destination parent folder is not writable.")
        }
    }

    private func writeMarker(_ marker: OwnershipMarker, at root: URL, replace: Bool = false) throws {
        let data = try JSONEncoder().encode(marker)
        let url = root.appendingPathComponent(Self.markerName)
        if replace {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ConfigurationMigrationError.unsafePath("Cannot record staging ownership.")
        }
    }

    private func marker(at root: URL) throws -> OwnershipMarker? {
        let url = root.appendingPathComponent(Self.markerName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ConfigurationMigrationError.unsafePath("The copy ownership marker is unsafe.")
        }
        return try JSONDecoder().decode(OwnershipMarker.self, from: Data(contentsOf: url))
    }

    private func fileDigests(in root: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw ConfigurationMigrationError.unsafePath("Published configurations cannot contain symbolic links.") }
            guard values.isRegularFile == true else { continue }
            let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            guard relative != Self.markerName else { continue }
            try MigrationSupport.validateRelativePath(relative)
            result[relative] = MigrationSupport.digest(try Data(contentsOf: url, options: [.mappedIfSafe]))
        }
        return result
    }

    private func removeOwnedStaging(_ stage: URL, operationID: UUID) throws {
        guard FileManager.default.fileExists(atPath: stage.path) else { return }
        guard try marker(at: stage)?.operationID == operationID else {
            throw ConfigurationMigrationError.unsafePath("The staging folder is not owned by this operation and was preserved.")
        }
        try FileManager.default.removeItem(at: stage)
    }
}
