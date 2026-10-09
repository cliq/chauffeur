import XCTest
import SwiftUI
import WebKit
@testable import Chauffeur

@MainActor
final class ReaderHTMLTests: XCTestCase {
    private static let fixture = """
    # Reader Heading

    <script>document.title = "executed"</script>

    [bad](javascript:alert(1)) [rel](../x.md) [anchor](#reader-heading)

    | A | B |
    |---|---|
    | 1 | 2 |

    - [x] done task
    - [ ] open task
    """

    func testRendersSafelyAndRerendersWithoutReload() async throws {
        let controller = UIHostingController(rootView: ReaderHTMLView(markdown: Self.fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        func findWebView(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWebView).first
        }
        var web: WKWebView?
        for _ in 0..<100 {
            web = findWebView(controller.view)
            if web != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let rendered = try XCTUnwrap(web)
        func waitForText(_ expected: String) async throws {
            for _ in 0..<100 {
                let text = try? await rendered.evaluateJavaScript("document.body.innerText") as? String
                if text?.contains(expected) == true { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("Reader did not render: \(expected)")
        }
        try await waitForText("Reader Heading")
        func eval(_ js: String) async throws -> Any? { try await rendered.evaluateJavaScript(js) }

        let body = try await eval("document.body.innerText") as? String ?? ""
        XCTAssertTrue(body.contains("document.title"), "script source should be shown as text")
        let title = try await eval("document.title") as? String
        let jsLinks = try await eval("document.querySelectorAll('a[href^=\"javascript\"]').length") as? Int
        let tables = try await eval("document.querySelectorAll('table').length") as? Int
        let checkboxes = try await eval("document.querySelectorAll('input[type=checkbox]').length") as? Int
        let headingID = try await eval("document.querySelector('h1').id") as? String
        XCTAssertNotEqual(title, "executed")
        XCTAssertEqual(jsLinks, 0)
        XCTAssertEqual(tables, 1)
        XCTAssertEqual(checkboxes, 2)
        XCTAssertFalse((headingID ?? "").isEmpty)
        let hrefs = try await eval("Array.from(document.querySelectorAll('a')).map(a => a.getAttribute('href'))") as? [String] ?? []
        XCTAssertTrue(hrefs.contains { $0.hasPrefix("chauffeur-reader://link/") })
        XCTAssertTrue(hrefs.contains("#reader-heading"))

        // Rerender in place: grow the page, scroll, change the markdown, and expect the scroll to survive.
        let long = Self.fixture + "\n\n" + (0..<200).map { "Paragraph \($0)\n" }.joined(separator: "\n")
        controller.rootView = ReaderHTMLView(markdown: long)
        try await waitForText("Paragraph 199")
        _ = try await eval("window.scrollTo(0, 300)")
        try await Task.sleep(for: .milliseconds(200))
        let before = try await eval("window.scrollY") as? Double ?? 0
        controller.rootView = ReaderHTMLView(markdown: long + "\n\nFresh addition")
        try await waitForText("Fresh addition")
        let after = try await eval("window.scrollY") as? Double ?? -1
        XCTAssertEqual(after, before, accuracy: 1)
        XCTAssertEqual(rendered.url?.host, "doc")
    }
}
