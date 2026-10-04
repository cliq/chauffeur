import Foundation
import Testing
import ChauffeurRemoteProtocol

struct SessionLinkTests {
    @Test(arguments: ["chauffeur", "chauffeur-debug"])
    func linksRoundTripUnderTheirOwnScheme(scheme: String) {
        let link = SessionLink(projectID: UUID(), sessionID: UUID())
        let url = link.url(scheme: scheme)
        #expect(url.absoluteString == "\(scheme)://session/\(link.projectID.uuidString)/\(link.sessionID.uuidString)")
        #expect(SessionLink(url: url, scheme: scheme) == link)
    }

    @Test func linksFromAnotherBuildAreRejected() {
        let link = SessionLink(projectID: UUID(), sessionID: UUID())
        #expect(SessionLink(url: link.url(scheme: "chauffeur"), scheme: "chauffeur-debug") == nil)
        #expect(SessionLink(url: link.url(scheme: "chauffeur-debug"), scheme: "chauffeur") == nil)
    }

    @Test func lowercaseUUIDsAreAccepted() throws {
        let project = UUID(), session = UUID()
        let text = "chauffeur://session/\(project.uuidString.lowercased())/\(session.uuidString.lowercased())"
        #expect(SessionLink(url: try #require(URL(string: text)), scheme: "chauffeur") == SessionLink(projectID: project, sessionID: session))
    }

    @Test func linksContainOnlyProjectAndSessionIdentity() throws {
        let link = SessionLink(projectID: UUID(), sessionID: UUID())
        let base = link.url(scheme: "chauffeur").absoluteString
        let rejected = [
            base + "?socket=/tmp/other",
            base + "#fragment",
            base + "/",
            base.replacingOccurrences(of: "session/", with: "user@session/"),
            base.replacingOccurrences(of: "session/", with: "user:secret@session/"),
            base.replacingOccurrences(of: "session/", with: "session:8080/"),
            base.replacingOccurrences(of: "chauffeur:", with: "https:"),
            base.replacingOccurrences(of: "://session/", with: "://open/"),
            "chauffeur://session/\(link.projectID.uuidString)",
            "chauffeur://session/\(link.projectID.uuidString)/\(link.sessionID.uuidString)/\(UUID().uuidString)",
            "chauffeur://session//\(link.sessionID.uuidString)",
            "chauffeur://session/not-a-uuid/\(link.sessionID.uuidString)",
            "chauffeur://session/../../etc",
            "chauffeur:/session/\(link.projectID.uuidString)/\(link.sessionID.uuidString)"
        ]
        for text in rejected {
            #expect(SessionLink(url: try #require(URL(string: text)), scheme: "chauffeur") == nil, "\(text)")
        }
    }
}
