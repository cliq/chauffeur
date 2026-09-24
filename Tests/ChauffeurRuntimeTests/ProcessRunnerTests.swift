import Foundation
import Testing
import ChauffeurCore
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

    /// Exit detection must not add a fixed delay: a launch runs dozens of short
    /// git and tmux commands in sequence.
    @Test func shortCommandsReturnPromptly() async throws {
        let start = ContinuousClock.now
        for _ in 0..<20 { #expect(try await ProcessRunner.run("/usr/bin/true", []).status == 0) }
        #expect(ContinuousClock.now - start < .milliseconds(600))
    }
    @Test func commandsStillTimeOut() async throws {
        let start = ContinuousClock.now
        var code: String?
        do { _ = try await ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.3) } catch let error as ChauffeurError { code = error.code }
        #expect(code == "command_timeout")
        #expect(ContinuousClock.now - start < .seconds(3))
    }
    @Test func cancellationStopsACommand() async throws {
        let start = ContinuousClock.now
        let task = Task { try await ProcessRunner.run("/bin/sleep", ["5"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(3))
    }
}
