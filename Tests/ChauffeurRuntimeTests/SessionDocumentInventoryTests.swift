import Foundation
import Testing
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

struct SessionDocumentInventoryTests {
    private typealias File = SessionDocumentInventory.File

    private func file(_ path: String, _ seconds: TimeInterval) -> File {
        File(path: path, modifiedAt: Date(timeIntervalSince1970: seconds), size: 10)
    }

    @Test func mergeOrdersMentionedFirstThenNewestChangedAndUnionsSources() {
        let merged = SessionDocumentInventory.merge(
            mentioned: [file("/work/b.md", 1), file("/Users/x/notes.md", 2), file("/work/b.md", 1)],
            changed: [file("/work/old.md", 5), file("/work/b.md", 1), file("/work/new.md", 9)],
            workingDirectory: "/work")
        #expect(merged.map(\.path) == ["/work/b.md", "/Users/x/notes.md", "/work/new.md", "/work/old.md"])
        #expect(merged[0].sources == [.mentioned, .changed])
        #expect(merged[1].sources == [.mentioned] && merged[2].sources == [.changed])
        #expect(merged[0].displayPath == "b.md" && merged[2].displayPath == "new.md")
    }

    @Test func mergeCapsTheListAndAbbreviatesPathsOutsideTheWorkingDirectory() {
        let many = (0..<150).map { file("/work/doc\($0).md", TimeInterval($0)) }
        #expect(SessionDocumentInventory.merge(mentioned: [], changed: many, workingDirectory: "/work").count == 100)
        let home = NSHomeDirectory()
        #expect(SessionDocumentInventory.displayPath("\(home)/notes/a.md", workingDirectory: "/work") == "~/notes/a.md")
        #expect(SessionDocumentInventory.displayPath("/work2/a.md", workingDirectory: "/work") == "/work2/a.md")
    }

    @Test func porcelainParsingKeepsMarkdownAndTakesRenameTargets() {
        let output = ["?? new.md", " M docs/mod.MD", "R  renamed.md", "old-name.md", " D gone.md", "?? code.swift", "A  added.markdown"].joined(separator: "\0") + "\0"
        #expect(SessionDocumentInventory.parsePorcelain(output) == ["new.md", "docs/mod.MD", "renamed.md", "added.markdown"])
    }

    @Test func changedFilesComeFromGitRelativeToTheRepositoryRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doc-inventory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ arguments: String...) async throws {
            let result = try await ProcessRunner.run("/usr/bin/git", ["-C", root.path, "-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments)
            try #require(result.status == 0)
        }
        func write(_ name: String, _ text: String) throws { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try await git("init", "-q")
        for name in ["modified.md", "rename-me.md", "deleted.md"] { try write(name, "# \(name)\n") }
        try write("sub/keep.md", "# keep\n")
        try await git("add", "-A"); try await git("commit", "-q", "-m", "base")
        try write("modified.md", "# changed\n")
        try await git("mv", "rename-me.md", "renamed.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.md"))
        try write("untracked.md", "# new\n"); try write("sub/untracked-sub.md", "# sub\n"); try write("code.swift", "let x = 1\n")
        let files = await SessionDocumentInventory.changedFiles(workingDirectory: root.appendingPathComponent("sub").path)
        let canonical = try #require(try? URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path)
        let names = Set(files.map { $0.path.replacingOccurrences(of: canonical + "/", with: "") })
        #expect(names == ["modified.md", "renamed.md", "untracked.md", "sub/untracked-sub.md"])
        // Outside a repository there is nothing to report.
        #expect(await SessionDocumentInventory.changedFiles(workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)").path).isEmpty)
    }
}
