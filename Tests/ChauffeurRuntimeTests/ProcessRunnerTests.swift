import Foundation
import Testing
@testable import ChauffeurRuntimeKit

struct ProcessRunnerTests {
    /// A busy runtime can saturate the shared Dispatch pool. Commands must still
    /// run and collect their output instead of waiting for a free worker.
    @Test func commandsCompleteWhileTheDispatchPoolIsSaturated() async throws {
        let release = DispatchSemaphore(value: 0)
        let workers = 256
        for _ in 0..<workers { DispatchQueue.global(qos: .userInitiated).async { release.wait() } }
        // Free the pool after a while even if the command is stuck behind it.
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 3); for _ in 0..<workers { release.signal() } }
        let start = ContinuousClock.now
        let result = try await ProcessRunner.run("/bin/echo", ["ready"], timeout: 5)
        #expect(result.status == 0 && result.output == "ready\n")
        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
