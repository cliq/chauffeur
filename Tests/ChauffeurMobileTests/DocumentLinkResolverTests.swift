import XCTest
@testable import Chauffeur

final class DocumentLinkResolverTests: XCTestCase {
    private let doc = "/Users/me/project/docs/plan.md"

    func testRelativeResolvesAgainstDocumentDirectory() {
        XCTAssertEqual(DocumentLinkResolver.resolve("other.md", relativeTo: doc), .document("/Users/me/project/docs/other.md"))
        XCTAssertEqual(DocumentLinkResolver.resolve("./sub/a.md", relativeTo: doc), .document("/Users/me/project/docs/sub/a.md"))
    }

    func testParentDirectoryIsStandardized() {
        XCTAssertEqual(DocumentLinkResolver.resolve("../x.md", relativeTo: doc), .document("/Users/me/project/x.md"))
    }

    func testFragmentAndQueryAreStripped() {
        XCTAssertEqual(DocumentLinkResolver.resolve("other.md#section", relativeTo: doc), .document("/Users/me/project/docs/other.md"))
        XCTAssertEqual(DocumentLinkResolver.resolve("other.md?x=1", relativeTo: doc), .document("/Users/me/project/docs/other.md"))
    }

    func testFragmentOnlyIsIgnored() {
        XCTAssertNil(DocumentLinkResolver.resolve("#top", relativeTo: doc))
        XCTAssertNil(DocumentLinkResolver.resolve("", relativeTo: doc))
    }

    func testPercentEncodingIsDecoded() {
        XCTAssertEqual(DocumentLinkResolver.resolve("my%20notes.md", relativeTo: doc), .document("/Users/me/project/docs/my notes.md"))
    }

    func testAbsolutePathIsKept() {
        XCTAssertEqual(DocumentLinkResolver.resolve("/etc/notes.md", relativeTo: doc), .document("/etc/notes.md"))
    }

    func testWebLinksOpenExternally() {
        XCTAssertEqual(DocumentLinkResolver.resolve("https://example.com/a?b=1#c", relativeTo: doc), .web(URL(string: "https://example.com/a?b=1#c")!))
        XCTAssertEqual(DocumentLinkResolver.resolve("mailto:a@b.com", relativeTo: doc), .web(URL(string: "mailto:a@b.com")!))
    }
}
