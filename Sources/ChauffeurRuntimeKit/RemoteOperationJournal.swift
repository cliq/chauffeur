import Foundation
import CryptoKit
import Darwin
import ChauffeurCore
import ChauffeurRemoteProtocol

/// One remote launch the host accepted, keyed by the client's operation key.
/// The journal outlives the process so a retry after a lost response, or after
/// the Mac restarted, resolves to the original worktree and session instead of
/// creating duplicates.
struct RemoteOperationRecord: Codable, Equatable, Sendable {
    var key: UUID
    var fingerprint: String
    var deviceID: UUID
    var status: OperationStatus
    /// The Worktree record ID a new-worktree launch creates; derived from `key`.
    var worktreeKey: UUID
    /// The Session record ID the launch creates; equal to `key`.
    var sessionKey: UUID
}

enum RemoteOperationKeys {
    static func sessionKey(for operationKey: UUID) -> UUID { operationKey }

    /// A deterministic UUID distinct from the operation key, so the Worktree
    /// and Session records created by one operation never share an ID.
    static func worktreeKey(for operationKey: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("worktree:\(operationKey.uuidString)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // RFC 4122 version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Atomic, 0600 JSON persistence at `<root>/runtime/remote-operations.json`.
actor RemoteOperationJournal {
    private struct Contents: Codable {
        var version = 1
        var records: [RemoteOperationRecord] = []
    }

    let root: URL
    private var records: [UUID: RemoteOperationRecord] = [:]

    init(root: URL) {
        self.root = root
    }

    var url: URL { root.appendingPathComponent("runtime/remote-operations.json") }

    /// Replaces the in-memory records with the persisted ones. An absent file is an empty journal.
    func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { records = [:]; return }
        do {
            let data = try Data(contentsOf: url)
            let contents = try JSONCoding.decode(Contents.self, from: data)
            records = Dictionary(contents.records.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
        } catch {
            throw ChauffeurError("remote_operations_corrupt", "Remote operation journal is corrupt", path: url.path)
        }
    }

    func record(for key: UUID) -> RemoteOperationRecord? { records[key] }

    func all() -> [RemoteOperationRecord] {
        records.values.sorted { $0.status.updatedAt < $1.status.updatedAt }
    }

    func upsert(_ record: RemoteOperationRecord) throws {
        records[record.key] = record
        try save()
    }

    private func save() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONCoding.encode(Contents(records: all()))
        let temp = directory.appendingPathComponent(".remote-operations-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ChauffeurError("remote_operations_write_failed", "Could not persist the remote operation journal", path: url.path)
        }
        guard Darwin.rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw ChauffeurError("remote_operations_write_failed", "Could not persist the remote operation journal", path: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
