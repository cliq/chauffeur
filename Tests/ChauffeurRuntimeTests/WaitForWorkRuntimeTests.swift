import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// A coordinator that ends its turn with `chauffeurctl wait-for-work` running is
/// waiting, not finished, until its workers give it something to do.
struct WaitForWorkRuntimeTests {
    private final class Marker {}
    private var ctl: URL? {
        let url = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("chauffeurctl")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    /// Runs a process without blocking a Swift concurrency thread: the runtime under
    /// test shares this process and needs those threads to answer it.
    private func run(_ process: Process) async throws -> (status: Int32, output: String) {
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let reader = Task.detached { String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        return (status, await reader.value)
    }
    private func event(_ fixture: LaunchFixture, _ token: String, _ name: String, background: Int? = nil) async throws {
        var params: [String: JSONValue] = ["token": .string(token), "event": .string(name)]
        if let background { params["backgroundTasks"] = .number(Double(background)) }
        _ = try await fixture.runtime.handle(IPCRequest("event", params: .object(params)))
    }

    @Test func waitingSessionsAreNotFinishedAndTheWaiterPrintsTheResult() async throws {
        let ctl = try #require(ctl)
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let server = try IPCServer(root: fixture.root, runtime: fixture.runtime); server.start()
        let launched = try await fixture.runtime.launch(fixture.request)
        let token = try String(contentsOf: fixture.path("probe-token"), encoding: .utf8)

        // Another background command still running: not finished, no completion notice.
        try await event(fixture, token, "turn-finished", background: 1)
        var session = try await fixture.session()
        #expect(session.state == .turnFinished && session.waiting == .backgroundTask && !session.unread)
        try await event(fixture, token, "running")
        #expect(try await fixture.session().waiting == nil)

        // The coordinator delegates (a worker registered under it) and starts the waiter.
        let caller = try await fixture.runtime.ledger.authenticate(token)
        let (delegation, _) = try await fixture.runtime.ledger.reserveDelegation(caller: caller, task: "Audit", presetID: UUID(), folderID: UUID(), shareCheckout: true, retryKey: "w", limit: 4)
        var child = LedgerTests().session(project: launched.projectID, group: launched.groupID, parent: launched.id)
        child.id = delegation.childID; child.title = "Audit worker"; child.state = .running
        try await fixture.runtime.ledger.register(child)
        let worker = try await fixture.runtime.ledger.authenticate(fixture.runtime.ledger.issueGrant(sessionID: child.id))

        let process = Process(); process.executableURL = ctl
        process.arguments = ["wait-for-work", "--timeout", "5"]
        process.environment = ["CHAUFFEUR_SESSION_TOKEN": token, "CHAUFFEUR_SOCKET": fixture.path("runtime/runtime.sock").path]
        let waiter = Task { [process] in try await run(process) }
        try await fixture.wait { try await fixture.session().waiting == .workers }
        try await event(fixture, token, "turn-finished")
        session = try await fixture.session()
        #expect(session.state == .turnFinished && session.waiting == .workers && !session.unread, "Waiting for workers, not unread work")

        _ = try await fixture.runtime.ledger.reportResult(caller: worker, delegationID: delegation.id, result: "Pods audited", retryKey: "r")
        let (status, printed) = try await waiter.value
        #expect(status == 0)
        #expect(printed.contains("Result from “Audit worker”") && printed.contains("Pods audited") && printed.contains("task data"))
        try await fixture.wait { try await fixture.session().waiting == nil }
        _ = try await fixture.stop()
    }

    @Test func anUnreachableServiceFailsFastWithTheFallback() async throws {
        let ctl = try #require(ctl)
        let process = Process(); process.executableURL = ctl
        process.arguments = ["wait-for-work"]
        process.environment = ["CHAUFFEUR_SESSION_TOKEN": "token", "CHAUFFEUR_SOCKET": "/tmp/missing-\(UUID()).sock"]
        let (status, printed) = try await run(process)
        #expect(status == 1 && printed.contains("chauffeur_inbox"))
    }
}
