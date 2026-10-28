import Foundation
import Testing
@testable import ChauffeurCore

struct LinkBrowserTests {
    @Test func teamsKeepTheirBrowserAndOlderTeamsUseTheDefault() throws {
        var team = PresetSet(name: "Cliq")
        team.linkBrowser = LinkBrowser(bundleID: "com.google.Chrome", profileDirectory: "Profile 1")
        let decoded = try JSONCoding.decode(PresetSet.self, from: JSONCoding.encode(team))
        #expect(decoded.linkBrowser == team.linkBrowser)
        try decoded.validate()

        var json = try JSONSerialization.jsonObject(with: JSONCoding.encode(team)) as! [String: Any]
        json.removeValue(forKey: "linkBrowser")
        #expect(try JSONCoding.decode(PresetSet.self, from: JSONSerialization.data(withJSONObject: json)).linkBrowser == nil)

        team.linkBrowser = LinkBrowser(bundleID: "")
        #expect(throws: (any Error).self) { try team.validate() }
    }

    @Test func chromiumProfilesComeFromLocalStateByName() throws {
        let localState = Data(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Cliq","user_name":"leo@cliq.example"},"Profile 2":{},"Profile 3":{"name":"Cliq","user_name":"ops@cliq.example"},"Profile 4":{"name":"Home"},"Profile 5":{"name":"Home"}}}}"#.utf8)
        // Profiles sharing a name show their account, or their directory without one.
        #expect(ChromiumProfiles.profiles(localState: localState).map(\.label) == [
            "Cliq (leo@cliq.example)", "Cliq (ops@cliq.example)", "Home (Profile 4)", "Home (Profile 5)", "Personal", "Profile 2",
        ])
        #expect(ChromiumProfiles.profiles(localState: localState).first?.directory == "Profile 1")
        #expect(ChromiumProfiles.profiles(localState: Data("{}".utf8)).isEmpty)

        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        let chrome = support.appendingPathComponent("Google/Chrome")
        try FileManager.default.createDirectory(at: chrome, withIntermediateDirectories: true)
        try localState.write(to: chrome.appendingPathComponent("Local State"))
        #expect(ChromiumProfiles.profiles(bundleID: "com.google.Chrome", applicationSupport: support).count == 6)
        #expect(ChromiumProfiles.profiles(bundleID: "com.apple.Safari", applicationSupport: support).isEmpty)
    }
}
