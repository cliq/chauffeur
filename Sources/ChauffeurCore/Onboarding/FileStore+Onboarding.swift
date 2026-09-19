import Foundation

public extension FileStore {
    func setupDraft() throws -> Stored<SetupDraft>? {
        try ensureSetupDirectory(root.appendingPathComponent("onboarding"))
        let url = root.appendingPathComponent("onboarding/setup-draft.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try readSetupRecord(SetupDraft.self, at: url)
    }

    @discardableResult
    func saveSetupDraft(_ value: SetupDraft, expectedVersion: String? = nil) throws -> Stored<SetupDraft> {
        try ensureSetupDirectory(root.appendingPathComponent("onboarding"))
        return try writeSetupRecord(value, at: root.appendingPathComponent("onboarding/setup-draft.json"), expectedVersion: expectedVersion)
    }

    func setupOperations() throws -> [Stored<SetupOperation>] {
        let directory = root.appendingPathComponent("onboarding/operations")
        let manager = FileManager.default
        try ensureSetupDirectory(root.appendingPathComponent("onboarding"))
        try ensureSetupDirectory(directory)
        let children = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try children
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try readSetupRecord(SetupOperation.self, at: $0) }
    }

    @discardableResult
    func saveSetupOperation(_ value: SetupOperation, expectedVersion: String? = nil) throws -> Stored<SetupOperation> {
        try ensureSetupDirectory(root.appendingPathComponent("onboarding"))
        try ensureSetupDirectory(root.appendingPathComponent("onboarding/operations"))
        let url = root.appendingPathComponent("onboarding/operations/\(value.id.uuidString).json")
        return try writeSetupRecord(value, at: url, expectedVersion: expectedVersion)
    }

    private func readSetupRecord<Value: Record>(_ type: Value.Type, at url: URL) throws -> Stored<Value> {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ChauffeurError("invalid_record", "Setup record must be a regular file", path: url.path)
        }
        let data = try Data(contentsOf: url)
        let value: Value
        do {
            value = try JSONCoding.decode(type, from: data)
            try value.validate()
        } catch let error as ChauffeurError {
            throw ChauffeurError(error.code, error.message, path: url.path)
        } catch {
            throw ChauffeurError("invalid_record", "Setup record has invalid JSON or schema", path: url.path)
        }
        return Stored(value: value, path: url.path, version: JSONCoding.digest(data))
    }

    private func writeSetupRecord<Value: Record>(_ value: Value, at url: URL, expectedVersion: String?) throws -> Stored<Value> {
        try value.validate()
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            guard let expectedVersion,
                  let existing = try? Data(contentsOf: url),
                  JSONCoding.digest(existing) == expectedVersion else {
                throw ChauffeurError("edit_conflict", "Setup changed. Reload before saving", path: url.path)
            }
        } else if expectedVersion != nil {
            throw ChauffeurError("edit_conflict", "Setup was removed. Reload before saving", path: url.path)
        }
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONCoding.encode(value)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return Stored(value: value, path: url.path, version: JSONCoding.digest(data))
    }

    private func ensureSetupDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ChauffeurError("invalid_record", "Setup metadata directory must not be a symlink", path: url.path)
            }
            return
        }
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
