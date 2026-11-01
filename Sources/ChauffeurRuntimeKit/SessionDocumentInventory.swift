import Foundation
import ChauffeurCore
import ChauffeurRemoteProtocol

/// Documents for a session: markdown and image paths its scrollback mentions plus changed or untracked markdown files
/// in its working directory. Changed images are left out so asset-heavy diffs don't crowd out the documents.
enum SessionDocumentInventory {
    static let maximumDocuments = 100

    struct File: Equatable, Sendable {
        var path: String
        var modifiedAt: Date
        var size: Int
    }

    static func build(session: Session, terminals: TmuxHost, scrollbackLines: Int) async -> [SessionDocument] {
        let workingDirectory = session.launch.workingDirectory, additionalPaths = session.launch.additionalPaths
        // A session that is not running has no pane to read; git can still contribute.
        let text = (try? await terminals.captureJoinedText(sessionID: session.id, lines: scrollbackLines)) ?? ""
        let mentioned = await Task.detached(priority: .utility) { () -> [File] in
            DocumentPathHarvester.paths(in: text).compactMap { candidate in
                file(at: DocumentFiles.resolve(candidate, workingDirectory: workingDirectory, additionalPaths: additionalPaths))
            }
        }.value
        let changed = await changedFiles(workingDirectory: workingDirectory)
        return merge(mentioned: mentioned, changed: changed, workingDirectory: workingDirectory)
    }

    /// An existing file the phone can open. Images are sent in chunks, so they may be larger than a text document.
    static func file(at path: String) -> File? {
        let limit = DocumentKind(path: path) == .image ? DocumentChunkRequest.maxTotalBytes : DocumentFiles.maximumBytes
        return (try? DocumentFiles.stat(path: path, limit: limit)).map { File(path: path, modifiedAt: $0.modifiedAt, size: $0.size) }
    }

    /// Mentioned files first in mention order, then changed-only files newest first.
    static func merge(mentioned: [File], changed: [File], workingDirectory: String) -> [SessionDocument] {
        var documents = [SessionDocument](), index = [String: Int]()
        for file in mentioned where index[file.path] == nil {
            index[file.path] = documents.count
            documents.append(document(file, sources: [.mentioned], workingDirectory: workingDirectory))
        }
        var changedOnly = [File]()
        for file in changed {
            if let position = index[file.path] { documents[position].sources.insert(.changed) }
            else if !changedOnly.contains(where: { $0.path == file.path }) { changedOnly.append(file) }
        }
        for file in changedOnly.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            documents.append(document(file, sources: [.changed], workingDirectory: workingDirectory))
        }
        return Array(documents.prefix(maximumDocuments))
    }

    static func displayPath(_ path: String, workingDirectory: String) -> String {
        // Document paths are standardized, which drops `/private` from `/private/tmp`; compare like with like.
        let standardized = (workingDirectory as NSString).standardizingPath
        let base = standardized.hasSuffix("/") ? standardized : standardized + "/"
        if !workingDirectory.isEmpty, path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        // `abbreviatingWithTildeInPath`, which swift-corelibs-foundation lacks.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Paths from `git status --porcelain=v1 -z`: renames and copies yield the new path, deletions are skipped.
    static func parsePorcelain(_ output: String) -> [String] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var paths = [String](), position = 0
        while position < records.count {
            let record = records[position]; position += 1
            guard record.count > 3 else { continue }
            let status = Array(record.prefix(2))
            // Renames and copies are followed by a record holding the original path.
            if status.contains("R") || status.contains("C") { position += 1 }
            guard !status.contains("D") else { continue }
            let path = String(record.dropFirst(3))
            if DocumentKind.markdownExtensions.contains((path as NSString).pathExtension.lowercased()) { paths.append(path) }
        }
        return paths
    }

    static func changedFiles(workingDirectory: String) async -> [File] {
        guard let root = try? await ProcessRunner.run("/usr/bin/git", ["-C", workingDirectory, "rev-parse", "--show-toplevel"], timeout: 5), root.status == 0,
              let status = try? await ProcessRunner.run("/usr/bin/git", ["-C", workingDirectory, "status", "--porcelain=v1", "-z", "--untracked-files=all"], timeout: 5), status.status == 0 else { return [] }
        let top = root.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !top.isEmpty else { return [] }
        let relative = parsePorcelain(status.output)
        return await Task.detached(priority: .utility) {
            relative.compactMap { name in
                let path = ((top as NSString).appendingPathComponent(name) as NSString).standardizingPath
                return (try? DocumentFiles.stat(path: path)).map { File(path: path, modifiedAt: $0.modifiedAt, size: $0.size) }
            }
        }.value
    }

    private static func document(_ file: File, sources: Set<SessionDocumentSource>, workingDirectory: String) -> SessionDocument {
        SessionDocument(path: file.path, displayPath: displayPath(file.path, workingDirectory: workingDirectory), sources: sources, modifiedAt: file.modifiedAt, size: file.size)
    }
}
