import Foundation
import Testing
@testable import ChauffeurRemoteProtocol

struct ModelTests {

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
