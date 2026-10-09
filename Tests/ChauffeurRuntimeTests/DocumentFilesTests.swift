import Foundation
import Testing
import Darwin
import ChauffeurCore

struct DocumentFilesTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let error as ChauffeurError { return error.code } catch { return "other" }
    }

    @Test func regularFilesReadWithModificationTimeAndStableVersion() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("plan.md")
        try "# Plan\n".write(to: file, atomically: true, encoding: .utf8)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let result = try DocumentFiles.read(path: file.path)
        #expect(result.text == "# Plan\n")
        #expect(result.stat.size == 7)
        #expect(abs(result.stat.modifiedAt.timeIntervalSince(modified)) < 0.001)
        #expect(try DocumentFiles.stat(path: file.path).version == result.stat.version)
        try "# Plan v2\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try DocumentFiles.stat(path: file.path).version != result.stat.version)
    }

    @Test func missingDirectoryFifoOversizedAndBinaryFilesAreRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(code { _ = try DocumentFiles.read(path: root.appendingPathComponent("missing.md").path) } == "document_not_found")
        #expect(code { _ = try DocumentFiles.read(path: root.path) } == "document_not_regular_file")
        let fifo = root.appendingPathComponent("pipe.md")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(code { _ = try DocumentFiles.stat(path: fifo.path) } == "document_not_regular_file")
        let big = root.appendingPathComponent("big.md")
        try Data(repeating: 97, count: DocumentFiles.maximumBytes + 1).write(to: big)
        #expect(code { _ = try DocumentFiles.read(path: big.path) } == "document_too_large")
        let binary = root.appendingPathComponent("binary.md")
        try Data([0xff, 0xfe, 0x00, 0x80]).write(to: binary)
        #expect(code { _ = try DocumentFiles.read(path: binary.path) } == "document_not_text")
    }

    @Test func pathsResolveAgainstHomeWorkingDirectoryAndAdditionalPaths() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work").path, extra = root.appendingPathComponent("extra").path
        try FileManager.default.createDirectory(atPath: work + "/docs", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: extra, withIntermediateDirectories: true)
        try "x".write(toFile: extra + "/only-extra.md", atomically: true, encoding: .utf8)
        try "x".write(toFile: work + "/docs/a.md", atomically: true, encoding: .utf8)

        #expect(DocumentFiles.resolve("~/notes.md", workingDirectory: work, additionalPaths: []) == NSHomeDirectory() + "/notes.md")
        #expect(DocumentFiles.resolve("/abs/../abs/x.md", workingDirectory: work, additionalPaths: []) == "/abs/x.md")
        #expect(DocumentFiles.resolve("docs/a.md", workingDirectory: work, additionalPaths: [extra]) == work + "/docs/a.md")
        #expect(DocumentFiles.resolve("./docs/a.md", workingDirectory: work, additionalPaths: []) == work + "/docs/a.md")
        #expect(DocumentFiles.resolve("../extra/only-extra.md", workingDirectory: work, additionalPaths: []) == extra + "/only-extra.md")
        #expect(DocumentFiles.resolve("only-extra.md", workingDirectory: work, additionalPaths: [extra]) == extra + "/only-extra.md")
        #expect(DocumentFiles.resolve("nope.md", workingDirectory: work, additionalPaths: [extra]) == work + "/nope.md")
    }
}
