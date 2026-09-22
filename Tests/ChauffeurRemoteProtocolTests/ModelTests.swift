import Foundation
import Testing
@testable import ChauffeurRemoteProtocol

struct ModelTests {
    @Test func progressIsOptionalForOlderInventoriesAndRoundTripsSeparately() throws {
        let session = SessionSummary(id: UUID(), projectID: UUID(), folderID: UUID(), title: "Task", kind: .codex, state: .running, checkoutPath: "/repo", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let legacy = try RemoteJSON.encode(session)
        #expect(try RemoteJSON.decode(SessionSummary.self, from: legacy).progress == nil)
        var updated = session
        updated.progress = SessionProgressSummary(title: "Task", now: "Building", percentComplete: 40)
        #expect(try RemoteJSON.decode(SessionSummary.self, from: RemoteJSON.encode(updated)) == updated)
        let request = RemoteOperation.getSessionProgress(SessionProgressRequest(sessionID: session.id))
        #expect(try RemoteJSON.decode(RemoteOperation.self, from: RemoteJSON.encode(request)) == request)
        let result = RemoteResult.sessionProgress(SessionProgressPanel(sessionID: session.id, summary: updated.progress!, json: "{}", html: "<html>Panel</html>"))
        #expect(try RemoteJSON.decode(RemoteResult.self, from: RemoteJSON.encode(result)) == result)
    }


    @Test(arguments: [
        (RemoteSessionState.starting, true),
        (.running, true),
        (.needsAttention, true),
        (.turnFinished, true),
        (.activityUnknown, true),
        (.exited, false),
        (.failed, false),
        (.interrupted, false)
    ])
    func isLiveTruthTable(state: RemoteSessionState, expectedIsLive: Bool) {
        #expect(state.isLive == expectedIsLive)
    }

    @Test func isLiveTruthTableCoversAllCases() {
        let coveredCases: Set<RemoteSessionState> = [
            .starting, .running, .needsAttention, .turnFinished, .activityUnknown,
            .exited, .failed, .interrupted
        ]
        #expect(coveredCases == Set(RemoteSessionState.allCases))
    }

    @Test func checkoutSummaryIdIsPath() {
        let checkout = CheckoutSummary(
            kind: .worktree,
            branch: "feature/x",
            path: "/tmp/checkout/feature-x",
            availability: .available
        )
        #expect(checkout.id == checkout.path)
    }
}
