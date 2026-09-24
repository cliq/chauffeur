import XCTest
import ChauffeurRemoteProtocol
@testable import Chauffeur

final class SessionKindTests: XCTestCase {
    func testOpenCodeAndUnknownAgentsHaveLabelsAndColours() throws {
        XCTAssertEqual(RemoteSessionKind.opencode.label, "OpenCode")
        XCTAssertEqual(RemoteSessionKind.opencode.badgeColorName, "teal")
        let unknown = try RemoteJSON.decode(RemoteSessionKind.self, from: Data(#""gemini""#.utf8))
        XCTAssertEqual(unknown.label, "Agent")
        XCTAssertNil(unknown.badgeColorName)
    }
}
