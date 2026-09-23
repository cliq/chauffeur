import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// Drives the built `chauffeurctl inbox-hook` the way Claude and Codex do:
/// payload on stdin, reminder JSON on stdout, and exit 0 whatever happens.
struct InboxHookCommandTests {
    private final class Marker {}
    /// `swift test` builds every product next to the test bundle.
    private var ctl: URL? {
        let url = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("chauffeurctl")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    private func run(_ ctl: URL, input: Data, token: String, socket: String, provider: String = "claude") throws -> (status: Int32, output: Data, elapsed: Duration) {
        let process = Process()
        process.executableURL = ctl
        process.arguments = ["inbox-hook", "--provider", provider]
        process.environment = ["CHAUFFEUR_SESSION_TOKEN": token, "CHAUFFEUR_SOCKET": socket]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let start = ContinuousClock.now
        try process.run()
        // Write concurrently: a payload larger than the pipe buffer must not deadlock.
        let writer = Thread { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
        writer.start()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output, start.duration(to: .now))
    }
    private func payload(_ event: String, session: String, extra: String = "") -> Data {
        Data(#"{"session_id":"\#(session)","hook_event_name":"\#(event)"\#(extra)}"#.utf8)
    }

    @Test func remindsOnceAndNeverFailsTheHook() async throws {
        let ctl = try #require(ctl, "chauffeurctl must be built next to the test bundle")
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let server = try IPCServer(root: fixture.root, runtime: fixture.runtime); server.start()
        let socket = fixture.path("runtime/runtime.sock").path
        let launched = try await fixture.runtime.launch(fixture.request)
        let token = try String(contentsOf: fixture.path("probe-token"), encoding: .utf8)
        let native = launched.id.uuidString.lowercased()

        let peer = LedgerTests().session(project: launched.projectID, group: launched.groupID)
        try await fixture.runtime.ledger.register(peer)
        let sender = try await fixture.runtime.ledger.authenticate(fixture.runtime.ledger.issueGrant(sessionID: peer.id))
        _ = try await fixture.runtime.ledger.send(caller: sender, recipientID: launched.id, body: "Never in hook output", retryKey: "one")

        let large = ",\"tool_response\":\"\(String(repeating: "x", count: 300_000))\",\"tool_use_id\":\"toolu_1\""
        let hinted = try run(ctl, input: payload("PostToolUse", session: native, extra: large), token: token, socket: socket)
        #expect(hinted.status == 0)
        let output = try JSONCoding.decode(JSONValue.self, from: hinted.output)
        #expect(output["hookSpecificOutput"]["hookEventName"].string == "PostToolUse")
        #expect(output["hookSpecificOutput"]["additionalContext"].string == InboxHintFormatter.text(InboxHintSummary(count: 1)))
        #expect(!String(decoding: hinted.output, as: UTF8.self).contains("Never in hook output"))

        let again = try run(ctl, input: payload("PostToolUse", session: native, extra: ",\"tool_use_id\":\"toolu_2\""), token: token, socket: socket)
        #expect(again.status == 0 && again.output.isEmpty)

        _ = try await fixture.runtime.ledger.send(caller: sender, recipientID: launched.id, body: "Late", retryKey: "two")
        let continued = try run(ctl, input: payload("Stop", session: native, extra: ",\"stop_hook_active\":true"), token: token, socket: socket)
        #expect(continued.status == 0 && continued.output.isEmpty, "A continued turn always ends")
        let stop = try run(ctl, input: payload("Stop", session: native, extra: ",\"stop_hook_active\":false"), token: token, socket: socket)
        #expect(try JSONCoding.decode(JSONValue.self, from: stop.output)["decision"].string == "block")

        for (input, token, socket, provider) in [
            (Data("garbage".utf8), token, socket, "claude"),
            (payload("SessionStart", session: native), token, socket, "claude"),
            (payload("PostToolUse", session: native), token, socket, "codex"),
            (payload("PostToolUse", session: native), "revoked-or-forged", socket, "claude"),
            (payload("PostToolUse", session: native), token, fixture.path("missing.sock").path, "claude"),
        ] {
            let result = try run(ctl, input: input, token: token, socket: socket, provider: provider)
            #expect(result.status == 0 && result.output.isEmpty)
            #expect(result.elapsed < .seconds(2))
        }
        _ = try await fixture.stop()
    }
}
