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

    /// OpenCode can't be suspended at all; Codex only with coordination, which the fixture leaves off.
    @Test(arguments: [(CLIKind.codex, "only with coordination on"), (.opencode, "can't be suspended yet")])
    func unsupportedAgentsBlockSuspension(kind: CLIKind, reason: String) async throws {
        let fixture = try await LaunchFixture.make(kind: kind); defer { fixture.cleanup() }
        let launched = try await fixture.runtime.launch(fixture.request)

        let plan = try await call(fixture, "suspendPlan").decode(ProjectSuspensionPlan.self)
        #expect(plan.blockers.map(\.sessionID) == [launched.id])
        #expect(plan.blockers.first?.reason.contains(reason) == true)
        _ = try await fixture.stop()
    }
}

/// Codex names its conversation only through trusted hooks, so it is suspended only when
/// they reported one with a transcript, and never on a transcript lookup.
struct CodexSuspensionPlanTests {
    private let projectID = UUID()
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    private func codex(inboxReminders: Bool?, conversation: String? = nil) -> Session {
        let set = PresetSet(name: "Fixture")
        let preset = AgentPreset(setID: set.id, name: "Codex", kind: .codex, executable: "/bin/cat", configurationDirectory: root.path)
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat", executableVersion: "fixture", workingDirectory: root.path, additionalPaths: [])
        var session = Session(projectID: projectID, groupID: UUID(), title: "Codex", launch: launch, folderID: UUID())
        session.state = .turnFinished
        session.inboxReminders = inboxReminders
        session.nativeConversationID = conversation
        return session
    }

    private func plan(_ session: Session, transcript: Bool) -> ProjectSuspensionPlan {
        let lookup = RecentConversation(id: UUID().uuidString.lowercased(), kind: .codex, title: "Newest", prompt: "Hi", startedAt: Date(), updatedAt: Date(),
                                        configurationDirectory: root.path, transcriptPath: root.path)
        return ProjectSuspensionPlanner.plan(projectID: projectID, sessions: [session], launching: [], hasRecordedTranscript: { _ in transcript }) { _ in [lookup] }
    }

    @Test func aReportedConversationWithATranscriptIsSuspended() {
        let conversation = UUID().uuidString.lowercased()
        let result = plan(codex(inboxReminders: true, conversation: conversation), transcript: true)
        #expect(result.canSuspend && result.agents.map(\.conversationID) == [conversation])
        #expect(result.agents.first?.conversationRecorded == true && result.agents.first?.activity == .idle)
    }

    @Test(arguments: [
        (Bool?.none, true, false, "only with coordination on"),
        (false, true, false, "didn't trust Chauffeur's hooks"),
        (true, false, false, "hasn't reported its conversation"),
        (true, true, false, "no saved transcript")
    ])
    func codexWithoutAVerifiedConversationBlocks(inboxReminders: Bool?, reported: Bool, transcript: Bool, reason: String) {
        let session = codex(inboxReminders: inboxReminders, conversation: reported ? UUID().uuidString.lowercased() : nil)
        let result = plan(session, transcript: transcript)
        // The newest transcript in the checkout is never adopted for Codex.
        #expect(result.agents.isEmpty && result.blockers.map(\.sessionID) == [session.id])
        #expect(result.blockers.first?.reason.contains(reason) == true)
    }

    @Test func aCodexRolloutCountsOnlyOnceItHasAMessage() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let folder = root.appendingPathComponent("sessions/2026/11/09")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rollout = folder.appendingPathComponent("rollout-2026-11-09T10-00-00-\(id).jsonl")
        func line(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) + Data("\n".utf8) }
        let meta = try line(["type": "session_meta", "payload": ["id": id, "cwd": root.path, "source": "cli"]])
        try meta.write(to: rollout)
        #expect(!RecentConversationScanner.hasTranscript(kind: .codex, id: id, checkout: root.path, configuration: root.path))

        let message = try line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Keep going"]]]])
        try (meta + message).write(to: rollout)
        #expect(RecentConversationScanner.hasTranscript(kind: .codex, id: id, checkout: root.path, configuration: root.path))
        #expect(!RecentConversationScanner.hasTranscript(kind: .codex, id: UUID().uuidString.lowercased(), checkout: root.path, configuration: root.path))
    }
}
