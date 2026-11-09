import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// Suspending a project stops its Claude Code sessions only once each has a
/// transcript to resume, and restoring resumes those same conversations.
@Suite(.serialized)
struct ProjectSuspensionTests {
    private func call(_ fixture: LaunchFixture, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        var params = params
        params["projectID"] = .string(fixture.request.projectID.uuidString)
        return try await fixture.runtime.handle(IPCRequest(method, params: .object(params)))
    }

    private func errorCode(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil }
        catch let error as ChauffeurError { return error.code }
        catch { return "\(error)" }
    }

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

    @Test func suspendStopsTheAgentAndRestoreResumesItsConversation() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)
        let conversation = try #require(launched.nativeConversationID)
        try writeClaudeTranscript(fixture, id: conversation)

        let plan = try await call(fixture, "suspendPlan").decode(ProjectSuspensionPlan.self)
        #expect(plan.canSuspend && plan.blockers.isEmpty)
        #expect(plan.agents.map(\.sessionID) == [launched.id])
        #expect(plan.agents.first?.conversationID == conversation && plan.agents.first?.conversationRecorded == true)

        // Basic terminal mode can't say whether the agent is idle, so interrupting needs consent.
        #expect(plan.agents.first?.activity == .unknown)
        #expect(await errorCode { _ = try await call(fixture, "suspendProject") } == "busy_sessions")
        #expect(try await fixture.session().state.isLive)
        _ = try await call(fixture, "suspendProject", ["interruptBusy": .bool(true)])
        let suspended = try await fixture.session()
        #expect(!suspended.state.isLive && suspended.suspendedAt != nil)

        // Nothing launches into a suspended project.
        var another = fixture.request; another.retryKey = UUID()
        #expect(await errorCode { _ = try await fixture.runtime.launch(another) } == "project_suspended")
        #expect(await errorCode { _ = try await call(fixture, "suspendPlan") } == "project_suspended")

        let result = try await call(fixture, "restoreProject", ["sessionIDs": .array([.string(launched.id.uuidString)])]).decode(ProjectRestoreResult.self)
        #expect(result.restored == [launched.id] && result.failures.isEmpty)
        let restored = try await fixture.session()
        #expect(restored.state.isLive && restored.suspendedAt == nil && restored.nativeConversationID == conversation)
        _ = try await fixture.stop()
    }

    @Test func aSessionWithoutATranscriptBlocksSuspension() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)

        let plan = try await call(fixture, "suspendPlan").decode(ProjectSuspensionPlan.self)
        #expect(!plan.canSuspend && plan.agents.isEmpty)
        #expect(plan.blockers.map(\.sessionID) == [launched.id])

        #expect(await errorCode { _ = try await call(fixture, "suspendProject", ["interruptBusy": .bool(true)]) } == "suspend_blocked")
        let session = try await fixture.session()
        #expect(session.state.isLive && session.suspendedAt == nil)
        _ = try await fixture.stop()
    }

    @Test func aMissingRecordedTranscriptFallsBackToTheCheckoutsNewest() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)
        // As after /clear in basic terminal mode: the agent writes to a conversation Chauffeur never heard of.
        let found = UUID().uuidString.lowercased()
        try writeClaudeTranscript(fixture, id: found)

        let plan = try await call(fixture, "suspendPlan").decode(ProjectSuspensionPlan.self)
        #expect(plan.agents.first?.conversationID == found && plan.agents.first?.conversationRecorded == false)

        _ = try await call(fixture, "suspendProject", ["interruptBusy": .bool(true)])
        let suspended = try await fixture.session()
        #expect(suspended.nativeConversationID == found && suspended.suspendedAt != nil)
        #expect(launched.nativeConversationID != found)
    }

    @Test func anOldRecordedTranscriptIsFoundBeyondTheNewestOnes() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)
        let conversation = try #require(launched.nativeConversationID)
        try writeClaudeTranscript(fixture, id: conversation)
        let folder = fixture.root.appendingPathComponent("projects").appendingPathComponent(RecentConversationScanner.claudeProjectFolder(Paths.canonical(fixture.root.path)))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: folder.appendingPathComponent("\(conversation).jsonl").path)
        // Newer conversations in the same checkout push it out of the recent list.
        for _ in 0..<60 { try writeClaudeTranscript(fixture, id: UUID().uuidString.lowercased()) }

        let plan = try await call(fixture, "suspendPlan").decode(ProjectSuspensionPlan.self)
        #expect(plan.agents.first?.conversationID == conversation && plan.agents.first?.conversationRecorded == true)
        _ = try await fixture.stop()
    }

    @Test func restoringNothingEndsTheSuspensionAndKeepsTheSessionResumable() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)
        try writeClaudeTranscript(fixture, id: try #require(launched.nativeConversationID))
        _ = try await call(fixture, "suspendProject", ["interruptBusy": .bool(true)])

        let result = try await call(fixture, "restoreProject", ["sessionIDs": .array([])]).decode(ProjectRestoreResult.self)
        #expect(result.restored.isEmpty && result.failures.isEmpty)
        let ended = try await fixture.session()
        #expect(!ended.state.isLive && ended.suspendedAt == nil && ended.nativeConversationID == launched.nativeConversationID)

        var another = fixture.request; another.retryKey = UUID()
        #expect(await errorCode { _ = try await fixture.runtime.launch(another) } != "project_suspended")
    }

    @Test func suspendedSessionsCanNeitherBeDeletedNorBypassedByResumingAnother() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        // An ended session from earlier work in the same project.
        var earlier = fixture.request; earlier.retryKey = UUID()
        _ = try await fixture.runtime.launch(earlier)
        _ = try await fixture.runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(earlier.retryKey.uuidString), "force": .bool(true)])))
        let launched = try await fixture.runtime.launch(fixture.request)
        try writeClaudeTranscript(fixture, id: try #require(launched.nativeConversationID))
        _ = try await call(fixture, "suspendProject", ["interruptBusy": .bool(true)])

        #expect(await errorCode {
            _ = try await fixture.runtime.handle(IPCRequest("deleteSession", params: .object(["sessionID": .string(launched.id.uuidString)])))
        } == "suspended_session")
        #expect(await errorCode {
            _ = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(earlier.retryKey.uuidString)])))
        } == "project_suspended")
        // Only a project restore resumes a suspended session.
        #expect(await errorCode {
            _ = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(launched.id.uuidString)])))
        } == "suspended_session")
        #expect(try await fixture.session().suspendedAt != nil)
    }

    @Test func aSessionThatFailsToResumeStaysSuspendedWithItsError() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)
        try writeClaudeTranscript(fixture, id: try #require(launched.nativeConversationID))
        _ = try await call(fixture, "suspendProject", ["interruptBusy": .bool(true)])

        // The agent's executable disappears while the project is suspended.
        let executable = fixture.path("fixture.py").path
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable) }
        let result = try await call(fixture, "restoreProject", ["sessionIDs": .array([.string(launched.id.uuidString)])]).decode(ProjectRestoreResult.self)

        #expect(result.restored.isEmpty && result.failures.map(\.sessionID) == [launched.id])
        let session = try await fixture.session()
        #expect(!session.state.isLive && session.suspendedAt != nil && session.error != nil)
        var another = fixture.request; another.retryKey = UUID()
        #expect(await errorCode { _ = try await fixture.runtime.launch(another) } == "project_suspended")
    }

    /// Codex reports its conversation only in coordination mode, so v1 suspends Claude Code alone.
    @Test(arguments: [CLIKind.codex, .opencode])
    func unsupportedAgentsBlockSuspension(kind: CLIKind) async throws {
        let fixture = try await LaunchFixture.make(kind: kind); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)

        let plan = try await call(fixture, "suspendPlan").decode(ProjectSuspensionPlan.self)
        #expect(plan.blockers.map(\.sessionID) == [launched.id])
        #expect(plan.blockers.first?.reason.contains("can't be suspended yet") == true)
        _ = try await fixture.stop()
    }
}
