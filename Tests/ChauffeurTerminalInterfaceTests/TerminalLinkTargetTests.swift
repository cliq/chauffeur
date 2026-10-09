import Foundation
import Testing
@testable import ChauffeurTerminalInterface

struct TerminalLinkTargetTests {
    @Test func webLinks() {
        #expect(TerminalLinkTarget.classify("https://example.com/a") == .web(URL(string: "https://example.com/a")!))
        #expect(TerminalLinkTarget.classify("HTTP://example.com") == .web(URL(string: "HTTP://example.com")!))
        #expect(TerminalLinkTarget.classify("mailto:a@b.com") == .web(URL(string: "mailto:a@b.com")!))
    }

    @Test func fileURLIsPercentDecoded() {
        #expect(TerminalLinkTarget.classify("file:///Users/a/b%20c.md") == .file(path: "/Users/a/b c.md"))
    }

    @Test func barePaths() {
        #expect(TerminalLinkTarget.classify("docs/x.md") == .file(path: "docs/x.md"))
        #expect(TerminalLinkTarget.classify("./x.md") == .file(path: "./x.md"))
        #expect(TerminalLinkTarget.classify("../x.md") == .file(path: "../x.md"))
        #expect(TerminalLinkTarget.classify("~/x.md") == .file(path: "~/x.md"))
        #expect(TerminalLinkTarget.classify("/abs/x") == .file(path: "/abs/x"))
    }

    @Test func lineSuffixIsStripped() {
        #expect(TerminalLinkTarget.classify("/abs/x.md:12:3") == .file(path: "/abs/x.md"))
        #expect(TerminalLinkTarget.classify("/abs/x.md:12") == .file(path: "/abs/x.md"))
        #expect(TerminalLinkTarget.classify("README.md:7") == .file(path: "README.md"))
        #expect(TerminalLinkTarget.classify("Sources/a.swift:10:2") == .file(path: "Sources/a.swift"))
    }

    @Test func bareNamesNeedKnownExtension() {
        #expect(TerminalLinkTarget.classify("README.md") == .file(path: "README.md"))
        #expect(TerminalLinkTarget.classify("main.SWIFT") == .file(path: "main.SWIFT"))
        #expect(TerminalLinkTarget.classify("example.com") == .other)
        #expect(TerminalLinkTarget.classify("www.foo.org") == .other)
        #expect(TerminalLinkTarget.classify("hello") == .other)
        #expect(TerminalLinkTarget.classify("") == .other)
    }

    @Test func otherSchemesAreIgnored() {
        #expect(TerminalLinkTarget.classify("javascript:alert(1)") == .other)
        #expect(TerminalLinkTarget.classify("ftp://host/x.md") == .other)
        #expect(TerminalLinkTarget.classify("vscode://file/x.md") == .other)
    }
}
