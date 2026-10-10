import Foundation
import Testing
@testable import ChauffeurCore

struct RemoteHostRouteTests {
    @Test func routesRoundTripWithAndWithoutAHost() throws {
        let id = UUID()
        #expect(RemoteHostRoute(url: RemoteHostRoute(hostID: id).url) == RemoteHostRoute(hostID: id))
        #expect(RemoteHostRoute(url: RemoteHostRoute(hostID: nil).url) == RemoteHostRoute(hostID: nil))
        #expect(RemoteHostRoute(url: URL(string: "\(AppBuild.current.urlScheme)://remote-host/not-a-uuid")!) == nil)
        #expect(RemoteHostRoute(url: WelcomeRoute.url) == nil)
    }

    @Test func listingReadsNamesAndIgnoresCredentials() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remote-hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let json = #"[{"hostID":"\#(id.uuidString)","name":"ubuntu-dev","host":"10.0.1.63","port":51847,"remoteAccessKey":"AAAA","deviceID":"\#(UUID().uuidString)","deviceToken":"secret","pairedAt":0}]"#
        try Data(json.utf8).write(to: url)
        #expect(RemoteHostListing.load(from: url) == [RemoteHostListing(hostID: id, name: "ubuntu-dev", host: "10.0.1.63", port: 51847)])
        #expect(RemoteHostListing.load(from: url.appendingPathExtension("missing")).isEmpty)
    }
}
