import XCTest
import SwiftUI
import WebKit
import ChauffeurRemoteProtocol
@testable import Chauffeur

@MainActor
final class ProgressHTMLTests: XCTestCase {
    func testSkillHTMLLoadsAndRefreshesCompanionData() async throws {
        let htmlURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "index", withExtension: "html"))
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        func panel(_ activity: String) throws -> SessionProgressPanel {
            let json = try JSONSerialization.data(withJSONObject: ["title": "Phone progress test", "subtitle": "Worker", "now": activity,
                "updated": "2026-09-22T12:00:00Z", "phases": [["title": "Capture", "detail": "Screenshots", "state": "active", "steps": []]]])
            return SessionProgressPanel(sessionID: UUID(), summary: SessionProgressSummary(title: "Test", now: activity, percentComplete: 50), json: String(decoding: json, as: UTF8.self), html: html)
        }
        let controller = UIHostingController(rootView: ProgressHTMLView(panel: try panel("Building the app")))
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
            XCTFail("Panel did not render: \(expected)")
        }
        try await waitForText("Building the app")
        let handler = try XCTUnwrap(rendered.configuration.urlSchemeHandler(forURLScheme: "chauffeur-progress") as? ProgressHTMLView.Coordinator)
        handler.panel = try panel("Capturing dark appearance")
        try await waitForText("Capturing dark appearance")
        XCTAssertEqual(rendered.url?.host, "panel")
        let snapshot = try await rendered.takeSnapshot(configuration: nil)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = "iPhone progress HTML"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
