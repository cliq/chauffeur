import Foundation
import Testing
import ChauffeurCore

struct NotificationRouteTests {
    @Test func routesContainOnlyProjectAndSessionIdentity() throws {
        let route = SessionRoute(projectID: UUID(), sessionID: UUID())
        #expect(SessionRoute(url: route.url) == route)
        for text in [route.url.absoluteString + "?socket=/tmp/other", route.url.absoluteString + "#fragment",
                     route.url.absoluteString + "/", route.url.absoluteString.replacingOccurrences(of: "session/", with: "user@session/"),
                     route.url.absoluteString.replacingOccurrences(of: "chauffeur:", with: "https:"),
                     "chauffeur://session//\(route.sessionID)", "chauffeur://session/../../etc"] {
            #expect(SessionRoute(url: try #require(URL(string: text))) == nil)
        }
    }
    @Test func notificationNamesAreBoundedAndControlCharactersRemoved() {
        let notice = AttentionNotice(route: SessionRoute(projectID: UUID(), sessionID: UUID()), reason: .input)
        let delivery = NotificationDelivery(notice: notice, project: "Project\n\u{1b}\u{202e}Name", session: String(repeating: "a", count: 500))
        #expect(delivery.project == "ProjectName")
        #expect(delivery.session.count == 120)
    }
}
