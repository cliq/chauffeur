import XCTest
import ChauffeurRemoteProtocol
import ChauffeurRemoteClient
import ChauffeurTerminalTesting
@testable import Chauffeur

@MainActor
final class SessionLinkRoutingTests: XCTestCase {
    private func link(for session: SessionSummary, scheme: String = MobileAppModel.urlScheme) -> URL {
        SessionLink(projectID: session.projectID, sessionID: session.id).url(scheme: scheme)
    }

    func testTheRegisteredURLSchemeIsTheOneTheModelAccepts() throws {
        // The plist gets $(CHAUFFEUR_URL_SCHEME) from the build configuration; the model uses #if DEBUG.
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [MobileAppModel.urlScheme])
    }

    func testLinkToALiveSessionOpensItsTerminal() async throws {
        let model = MobileAppModel.preview()
        let target = try XCTUnwrap(model.liveSessions.last)
        XCTAssertFalse(model.openTabs.contains(target.id))

        await model.openSessionURL(link(for: target))?.value

        XCTAssertNil(model.pendingSessionRoute)
        XCTAssertEqual(model.path, [.sessions, .terminal])
        XCTAssertEqual(model.selectedTab, target.id)
        XCTAssertTrue(model.openTabs.contains(target.id))
        XCTAssertNil(model.connectError)
    }

    func testLinkToAnUnknownSessionShowsTheListWithAMessage() async {
        let model = MobileAppModel.preview()
        model.path = [.sessions, .terminal]
        let tabs = model.openTabs
        let url = SessionLink(projectID: UUID(), sessionID: UUID()).url(scheme: MobileAppModel.urlScheme)

        await model.openSessionURL(url)?.value

        XCTAssertNil(model.pendingSessionRoute)
        XCTAssertEqual(model.path, [.sessions])
        XCTAssertEqual(model.openTabs, tabs)
        XCTAssertEqual(model.connectError, "That session is no longer available on Leo's Mac.")
    }

    func testLinkWhoseProjectDoesNotMatchTheSessionIsRejected() async throws {
        let model = MobileAppModel.preview()
        let target = try XCTUnwrap(model.liveSessions.last)
        let url = SessionLink(projectID: UUID(), sessionID: target.id).url(scheme: MobileAppModel.urlScheme)

        await model.openSessionURL(url)?.value

        XCTAssertNil(model.pendingSessionRoute)
        XCTAssertNotEqual(model.selectedTab, target.id)
        XCTAssertNotNil(model.connectError)
    }

    func testLinksForAnotherBuildOrMalformedAreIgnored() throws {
        let model = MobileAppModel.preview()
        let target = try XCTUnwrap(model.liveSessions.last)
        let otherScheme = MobileAppModel.urlScheme == "chauffeur" ? "chauffeur-debug" : "chauffeur"
        let urls = [
            link(for: target, scheme: otherScheme),
            try XCTUnwrap(URL(string: "\(MobileAppModel.urlScheme)://session/\(target.id.uuidString)")),
            try XCTUnwrap(URL(string: "\(MobileAppModel.urlScheme)://welcome")),
            try XCTUnwrap(URL(string: "https://example.com/session/\(target.projectID)/\(target.id)"))
        ]
        let path = model.path, tabs = model.openTabs, selected = model.selectedTab

        for url in urls {
            XCTAssertNil(model.openSessionURL(url), url.absoluteString)
        }

        XCTAssertNil(model.pendingSessionRoute)
        XCTAssertEqual(model.path, path)
        XCTAssertEqual(model.openTabs, tabs)
        XCTAssertEqual(model.selectedTab, selected)
        XCTAssertNil(model.connectError)
    }

    func testLinkWaitsWhileDisconnected() {
        // No saved Mac, so nothing connects; the link stays pending for the next `connect()`.
        let model = MobileAppModel(
            credentials: InMemoryCredentialStore(),
            makeJournal: { _ in InMemoryOperationJournal() },
            defaults: nil,
            makeTerminalAdapter: { FakeTerminalEngineAdapter() }
        )
        let route = SessionLink(projectID: UUID(), sessionID: UUID())

        XCTAssertNil(model.openSessionURL(route.url(scheme: MobileAppModel.urlScheme)))

        XCTAssertEqual(model.pendingSessionRoute, route)
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertNil(model.connectError)
    }
}
