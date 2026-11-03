import AppKit
import Foundation
import GhosttyKit
import Testing
@testable import ChauffeurTerminalGhostty

struct WrappedLinkTests {
    /// Claude Code's layout: an indented URL broken at the right edge, continued at the same indent.
    private let rows = [
        "  Open this link, which should start a link post:",
        "",
        "  https://www.reddit.com/r/Playden_PS5/submit/?type=LINK",
        "  &title=Play%20with&url=https%3A%2F%2Fplayden.club%2Fb",
        "  log%2Fplay.",
        "",
        "  If it opens the text composer anyway, paste the URL.",
    ]
    private let url = "https://www.reddit.com/r/Playden_PS5/submit/?type=LINK&title=Play%20with&url=https%3A%2F%2Fplayden.club%2Fblog%2Fplay"

    @Test func joinsAWrappedURLFromAnyOfItsRows() {
        #expect(WrappedLink.url(rows: rows, row: 2, column: 10, columns: 56) == url)
        #expect(WrappedLink.url(rows: rows, row: 3, column: 30, columns: 56) == url)
        #expect(WrappedLink.url(rows: rows, row: 4, column: 4, columns: 56) == url)
    }

    @Test func leavesOneRowURLsAndProseToGhostty() {
        #expect(WrappedLink.url(rows: ["see https://example.com/a here"], row: 0, column: 8, columns: 80) == nil)
        #expect(WrappedLink.url(rows: rows, row: 0, column: 4, columns: 56) == nil)
        #expect(WrappedLink.url(rows: rows, row: 6, column: 4, columns: 56) == nil)
        // The row isn't full, so the next row is not a continuation.
        #expect(WrappedLink.url(rows: rows, row: 2, column: 10, columns: 70) == nil)
    }

    @Test func aFullRowOfProseAboveIsNotPartOfTheURL() {
        let rows = ["word word word word", "https://example.com/a", "bc"]
        #expect(WrappedLink.url(rows: rows, row: 1, column: 3, columns: 21) == "https://example.com/abc")
        #expect(WrappedLink.url(rows: rows, row: 2, column: 0, columns: 21) == "https://example.com/abc")
    }

    @Test func proseBesideAWrappedURLStaysOut() {
        // A full row of prose ending in a word, then a URL at the start of the next row.
        let after = ["prose ends with hello", "https://example.com/a", "bc"]
        #expect(WrappedLink.url(rows: after, row: 1, column: 4, columns: 21) == "https://example.com/abc")
        #expect(WrappedLink.url(rows: after, row: 0, column: 18, columns: 21) == nil)
        // A whole URL that ends at the edge, then prose.
        let before = ["https://example.com/a", "  Read the docs"]
        #expect(WrappedLink.url(rows: before, row: 0, column: 10, columns: 21) == nil)
        #expect(WrappedLink.url(rows: before, row: 1, column: 3, columns: 21) == nil)
        // A continuation with URL punctuation is still joined when prose follows it.
        let tail = ["https://example.com/a", "  b/c then text"]
        #expect(WrappedLink.url(rows: tail, row: 0, column: 10, columns: 21) == "https://example.com/ab/c")
    }

    @Test func findsASchemeSplitAcrossRows() {
        let rows = [String(repeating: " ", count: 19) + "ht", "  tps://example.com/a", "  bc"]
        #expect(WrappedLink.url(rows: rows, row: 0, column: 19, columns: 21) == "https://example.com/abc")
        #expect(WrappedLink.url(rows: rows, row: 2, column: 2, columns: 21) == "https://example.com/abc")
    }

    @Test func dropsTrailingPunctuationAndUnopenedBrackets() {
        let rows = ["(see https://example.com/wiki/A_(b", ")_c)."]
        #expect(WrappedLink.url(rows: rows, row: 0, column: 10, columns: 34) == "https://example.com/wiki/A_(b)_c")
    }
}

@MainActor
struct WrappedLinkSurfaceTests {
    @Test func clickingAnyRowOfAWrappedURLFindsAllOfIt() throws {
        let adapter = GhosttyTerminalAdapter()
        let view = adapter.makeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = window.contentView!.bounds
        guard let surfaceView = view as? GhosttySurfaceView, surfaceView.surface != nil else {
            Issue.record("No Ghostty surface in a test window"); return
        }
        let columns = Int(ghostty_surface_size(try #require(surfaceView.surface)).columns)
        let head = "  https://example.com/"
        let first = head + String(repeating: "a", count: columns - head.count)
        adapter.feed(Data("\u{1b}[H\u{1b}[2J\(first)\r\n  bcd/e and more\r\n".utf8))
        adapter.waitForPendingOutput()
        let expected = "https://example.com/" + String(repeating: "a", count: columns - head.count) + "bcd/e"
        #expect(surfaceView.wrappedLink(at: point(surfaceView, column: 5, row: 0)) == expected)
        #expect(surfaceView.wrappedLink(at: point(surfaceView, column: 4, row: 1)) == expected)
        #expect(surfaceView.wrappedLink(at: point(surfaceView, column: 10, row: 1)) == nil)
        adapter.dispose()
    }

    /// The centre of a cell, in view coordinates.
    private func point(_ view: GhosttySurfaceView, column: Int, row: Int) -> NSPoint {
        let size = ghostty_surface_size(view.surface!)
        let scale = Double(size.width_px) / view.bounds.width
        let padX = (Double(size.width_px) - Double(size.columns) * Double(size.cell_width_px)) / 2
        let padY = (Double(size.height_px) - Double(size.rows) * Double(size.cell_height_px)) / 2
        let x = (padX + (Double(column) + 0.5) * Double(size.cell_width_px)) / scale
        let y = (padY + (Double(row) + 0.5) * Double(size.cell_height_px)) / scale
        return NSPoint(x: x, y: view.bounds.height - y)
    }
}
