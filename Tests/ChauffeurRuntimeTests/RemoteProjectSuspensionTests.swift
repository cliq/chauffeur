import Foundation
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

/// A paired device suspends and restores a project through the remote operations, and the
/// inventory tells it which sessions wait for the restore.
@Suite(.serialized)
struct RemoteProjectSuspensionTests {
    /// A Claude Code transcript for the checkout, as `RecentConversationScanner` reads it.
    private func writeClaudeTranscript(_ fixture: LaunchFixture, id: String) throws {
        let checkout = Paths.canonical(fixture.root.path)
        let folder = fixture.root.appendingPathComponent("projects").appendingPathComponent(RecentConversationScanner.claudeProjectFolder(checkout))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = try JSONSerialization.data(withJSONObject: [
            "type": "user", "cwd": checkout, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "message": ["role": "user", "content": "Keep working on suspension"]
        ])
        try (line + Data("\n".utf8)).write(to: folder.appendingPathComponent("\(id).jsonl"))
    }

    @Test func remoteSuspendAndRestoreRoundTripTheProject() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let handlers = RemoteOperationHandlers(runtime: fixture.runtime, root: fixture.root, hostName: "Fixture", isAttached: { _ in false })
        let projectID = fixture.request.projectID
        let launched = try await fixture.runtime.launch(fixture.request)
        try writeClaudeTranscript(fixture, id: try #require(launched.nativeConversationID))

        guard case .success(.suspendPlan(let plan)) = await handlers.handle(.getSuspendPlan(SuspendPlanRequest(projectID: projectID)), deviceID: UUID()) else {
            Issue.record("No suspend plan"); return
        }
        #expect(plan.canSuspend && plan.agents.map(\.sessionID) == [launched.id])
        #expect(plan.agents.first?.kind == .claude && plan.agents.first?.conversationRecorded == true)
        // Basic terminal mode can't say whether the agent is idle, so suspending needs consent.
        #expect(plan.agents.first?.activity == .unknown)
        guard case .failure(let busy) = await handlers.handle(.suspendProject(SuspendProjectRequest(projectID: projectID, interruptBusy: false)), deviceID: UUID()) else {
            Issue.record("Suspended without consent"); return
        }
        #expect(busy.code == "busy_sessions")

        guard case .success(.ack) = await handlers.handle(.suspendProject(SuspendProjectRequest(projectID: projectID, interruptBusy: true)), deviceID: UUID()) else {
            Issue.record("Suspend was not acknowledged"); return
        }
        let suspended = try #require(try await handlers.inventory().sessions.first { $0.id == launched.id })
        #expect(!suspended.state.isLive && suspended.suspendedAt != nil && suspended.restoreError == nil)
        guard case .failure(let again) = await handlers.handle(.getSuspendPlan(SuspendPlanRequest(projectID: projectID)), deviceID: UUID()) else {
            Issue.record("A suspended project was planned again"); return
        }
        #expect(again.code == "project_suspended")

        // A launch into the suspended project is refused before it creates a worktree.
        let worktreesBefore = await fixture.runtime.store.reload().worktrees.count
        let launch = LaunchOperationRequest(operationKey: UUID(), fingerprint: "suspended", newWorktree: WorktreeCreationSpec(branch: "feature/while-suspended", baseRef: "HEAD"),
                                            launch: LaunchSpec(projectID: projectID, folderID: fixture.request.folderID))
        guard case .success(.operation(let refused)) = await handlers.handle(.launch(launch), deviceID: UUID()) else {
            Issue.record("No launch status"); return
        }
        #expect(refused.phase == .failed && refused.error?.code == "project_suspended" && refused.worktreeID == nil)
        #expect(await fixture.runtime.store.reload().worktrees.count == worktreesBefore)

        // A list that doesn't show every suspended session can't end the ones it left out.
        guard case .failure(let changed) = await handlers.handle(.restoreProject(RestoreProjectRequest(projectID: projectID, sessionIDs: [], shownSessionIDs: [])), deviceID: UUID()) else {
            Issue.record("Restored from a stale list"); return
        }
        #expect(changed.code == "suspension_changed")
        #expect(try await handlers.inventory().sessions.first { $0.id == launched.id }?.suspendedAt != nil)

        guard case .success(.restoreResult(let result)) = await handlers.handle(.restoreProject(RestoreProjectRequest(projectID: projectID, sessionIDs: [launched.id], shownSessionIDs: [launched.id])), deviceID: UUID()) else {
            Issue.record("Restore failed"); return
        }
        #expect(result.restored == [launched.id] && result.failures.isEmpty)
        let restored = try #require(try await handlers.inventory().sessions.first { $0.id == launched.id })
        #expect(restored.state.isLive && restored.suspendedAt == nil)
        _ = try await fixture.stop()
    }
}
