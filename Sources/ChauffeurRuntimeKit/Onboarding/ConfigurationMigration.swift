import ChauffeurCore
import CryptoKit
import Foundation

public protocol ConfigurationMigration: Sendable {
    func availableProjects(sourcePath: String) throws -> [String]
    func preview(pair: SetupAgentPair) throws -> CopyPreview
    func write(preview: CopyPreview, pair: SetupAgentPair, staging: URL) throws
}

public extension ConfigurationMigration {
    func availableProjects(sourcePath: String) throws -> [String] { [] }
}

public enum ConfigurationMigrationError: Error, LocalizedError, Equatable {
    case invalidPair(String)
    case sourceChanged(String)
    case unsafePath(String)
    case unsupportedFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPair(let message), .sourceChanged(let message),
             .unsafePath(let message), .unsupportedFile(let message): message
        }
    }
}

enum MigrationSupport {
    static let credentialNames: Set<String> = [
        "auth.json", ".credentials.json", "credentials.json", "oauth.json", "tokens.json",
        "account.json", "login.json", "session.json", ".session", "keychain"
    ]

    static func excludedAsset(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let name = component.lowercased()
            return credentialNames.contains(name) || [".git", ".cache", "logs", "debug", "tmp", ".ds_store"].contains(name)
                || name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".lock") || name.hasSuffix(".sock")
                || name == "credentials" || name == "tokens" || name == "auth"
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digestFile(_ url: URL) throws -> (digest: String, size: Int64) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw ConfigurationMigrationError.unsupportedFile("Skipped \(url.lastPathComponent): it is not a regular file.")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return (digest(data), Int64(values.fileSize ?? data.count))
    }

    static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else {
            throw ConfigurationMigrationError.unsafePath("Copy paths must be relative.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(".."), !components.contains("."), !components.contains("") else {
            throw ConfigurationMigrationError.unsafePath("Unsafe copy path: \(path)")
        }
    }

    static func validatePair(_ pair: SetupAgentPair) throws -> (source: URL?, destination: URL) {
        let destination = URL(fileURLWithPath: Paths.canonical(pair.destinationPath)).standardizedFileURL
        guard destination.path.hasPrefix("/") else {
            throw ConfigurationMigrationError.invalidPair("Choose an absolute destination folder.")
        }
        guard let sourcePath = pair.sourcePath else { return (nil, destination) }
        let source = URL(fileURLWithPath: Paths.canonical(sourcePath)).standardizedFileURL
        let resolvedDestination = URL(fileURLWithPath: Paths.canonical(destination.path)).standardizedFileURL
        guard source.path != resolvedDestination.path else {
            throw ConfigurationMigrationError.invalidPair("Source and destination must be different folders.")
        }
        guard !resolvedDestination.path.hasPrefix(source.path + "/") else {
            throw ConfigurationMigrationError.invalidPair("Destination cannot be inside the source folder.")
        }
        return (source, destination)
    }

    static func selectionDigest(pair: SetupAgentPair, entries: [CopyEntry], warnings: [String]) -> String {
        let categories = pair.categories.map(\.rawValue).sorted().joined(separator: "\u{0}")
        let projects = pair.projectPaths.sorted().joined(separator: "\u{0}")
        let files = entries.sorted { $0.destinationRelativePath < $1.destinationRelativePath }.map {
            "\($0.sourceRelativePath)\u{0}\($0.destinationRelativePath)\u{0}\($0.category.rawValue)\u{0}\($0.sourceDigest)"
        }.joined(separator: "\u{1}")
        return digest(Data("\(pair.id.uuidString)\u{0}\(pair.sourcePath ?? "")\u{0}\(pair.destinationPath)\u{0}\(categories)\u{0}\(projects)\u{0}\(files)\u{0}\(warnings.joined(separator: "\u{1}"))".utf8))
    }

    static func enumerateFiles(
        sourceRoot: URL, relativeRoot: String, category: CopyCategory,
        into entries: inout [CopyEntry], warnings: inout [String]
    ) throws {
        try validateRelativePath(relativeRoot)
        let root = sourceRoot.appendingPathComponent(relativeRoot, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot.path.hasPrefix(sourceRoot.path + "/") else {
            warnings.append("Skipped \(relativeRoot): its folder points outside the source.")
            return
        }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else { return }
        for case let url as URL in enumerator {
            // FileManager may return `/private/var/...` URLs after being given
            // the equivalent `/var/...` URL. Enumerator depth avoids brittle
            // string-prefix arithmetic across those filesystem aliases.
            let descendant = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
            let relative = relativeRoot + (descendant.isEmpty ? "" : "/" + descendant)
            let values = try url.resourceValues(forKeys: keys)
            if excludedAsset(relative) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                warnings.append("Skipped \(relative): credentials or transient state are not copied.")
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                let target = url.resolvingSymlinksInPath().standardizedFileURL
                if excludedAsset(String(target.path.dropFirst(sourceRoot.path.count + 1))) {
                    warnings.append("Skipped \(relative): its link targets excluded state.")
                    continue
                }
                guard target.path.hasPrefix(sourceRoot.path + "/"), FileManager.default.fileExists(atPath: target.path) else {
                    warnings.append("Skipped \(relative): its link is broken or points outside the source folder.")
                    continue
                }
                guard (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    warnings.append("Skipped \(relative): linked directories are not copied.")
                    continue
                }
                let file = try digestFile(target)
                entries.append(CopyEntry(sourceRelativePath: relative, destinationRelativePath: relative, category: category, sourceDigest: file.digest, size: file.size))
            } else if values.isRegularFile == true {
                let file = try digestFile(url)
                entries.append(CopyEntry(sourceRelativePath: relative, destinationRelativePath: relative, category: category, sourceDigest: file.digest, size: file.size))
            }
        }
    }

    static func verify(preview: CopyPreview, against current: CopyPreview) throws {
        guard preview.pairID == current.pairID,
              preview.sourcePath == current.sourcePath,
              preview.destinationPath == current.destinationPath,
              preview.selectionDigest == current.selectionDigest,
              preview.entries == current.entries else {
            throw ConfigurationMigrationError.sourceChanged("The source, destination, selection, or selected files changed after preview. Review the copy again.")
        }
    }

    static func write(
        preview: CopyPreview, pair: SetupAgentPair, staging: URL,
        transform: (CopyEntry, Data) throws -> Data
    ) throws {
        guard let sourcePath = pair.sourcePath else { return }
        let source = URL(fileURLWithPath: Paths.canonical(sourcePath)).standardizedFileURL
        for entry in preview.entries {
            try validateRelativePath(entry.sourceRelativePath)
            try validateRelativePath(entry.destinationRelativePath)
            guard !excludedAsset(entry.sourceRelativePath), !excludedAsset(entry.destinationRelativePath) else {
                throw ConfigurationMigrationError.unsafePath("Credentials and transient state cannot be copied.")
            }
            let sourceURL = source.appendingPathComponent(entry.sourceRelativePath)
            let resolvedSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedSource.path.hasPrefix(source.path + "/") else {
                throw ConfigurationMigrationError.sourceChanged("A selected link now points outside the source folder: \(entry.sourceRelativePath)")
            }
            guard !excludedAsset(String(resolvedSource.path.dropFirst(source.path.count + 1))) else {
                throw ConfigurationMigrationError.sourceChanged("A selected link now points at excluded state.")
            }
            let data = try Data(contentsOf: resolvedSource, options: [.mappedIfSafe])
            guard digest(data) == entry.sourceDigest else {
                throw ConfigurationMigrationError.sourceChanged("A selected file changed after preview: \(entry.sourceRelativePath)")
            }
            let output = try transform(entry, data)
            let destinationURL = staging.appendingPathComponent(entry.destinationRelativePath)
            let parent = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let mode = (try FileManager.default.attributesOfItem(atPath: resolvedSource.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let permissions = mode & 0o111 == 0 ? 0o600 : 0o700
            guard FileManager.default.createFile(atPath: destinationURL.path, contents: output, attributes: [.posixPermissions: permissions]) else {
                throw ConfigurationMigrationError.unsafePath("Cannot create \(entry.destinationRelativePath) in staging.")
            }
        }
    }
}
