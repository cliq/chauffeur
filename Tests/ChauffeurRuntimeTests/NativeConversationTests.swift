import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// Claude's `/clear` and `/resume` continue in another native conversation
/// without restarting the process Chauffeur launched.
struct NativeConversationTests {
    private func launch(_ fixture: LaunchFixture, _ request: LaunchRequest) async throws -> (Session, String) {
        try? FileManager.default.removeItem(at: fixture.path("probe-token"))
        let session = try await fixture.runtime.launch(request)
        let token = try String(contentsOf: fixture.path("probe-token"), encoding: .utf8)
        return (session, token)
    }
    private func event(_ fixture: LaunchFixture, _ session: Session, token: String, _ event: String, native: String?, hook: String? = nil, source: String? = nil) async throws -> Session {
        var params: [String: JSONValue] = ["sessionID": .string(session.id.uuidString), "token": .string(token), "event": .string(event)]
        if let native { params["nativeConversationID"] = .string(native) }
        if let hook { params["hookEvent"] = .string(hook) }
        if let source { params["source"] = .string(source) }
        _ = try await fixture.runtime.handle(IPCRequest("event", params: .object(params)))
        return try #require(await fixture.runtime.snapshot()["sessions"].decode([Session].self).first { $0.id == session.id })
    }

    @Test func lifecycleEventsFollowClearAndResumeAndKeepStateOnMismatch() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let (launched, token) = try await launch(fixture, fixture.request)
        let original = try #require(launched.nativeConversationID)
        #expect(original == launched.id.uuidString)

        // Providers report lowercase IDs; that is the same conversation.
        var session = try await event(fixture, launched, token: token, "turn-finished", native: original.lowercased(), hook: "Stop")
        #expect(session.state == .turnFinished && session.nativeConversationID == original)

        // A different ID outside SessionStart is recorded but neither fails nor moves the session.
        let stray = UUID().uuidString.lowercased()
        for (name, hook, expected) in [("running", "PostToolUse", SessionState.running), ("needs-attention", "Notification", .needsAttention), ("turn-finished", "Stop", .turnFinished)] {
            session = try await event(fixture, launched, token: token, name, native: stray, hook: hook)
            #expect(session.state == expected && session.nativeConversationID == original)
        }
        session = try await event(fixture, launched, token: token, "running", native: stray, hook: "SessionStart", source: "startup")
        #expect(session.nativeConversationID == original)

        let cleared = UUID().uuidString.lowercased()
        session = try await event(fixture, launched, token: token, "running", native: cleared, hook: "SessionStart", source: "clear")
        #expect(session.state == .running && session.nativeConversationID == cleared && session.conversationWarning == nil)
        session = try await event(fixture, launched, token: token, "running", native: original, hook: "SessionStart", source: "resume")
        #expect(session.nativeConversationID == original)
        session = try await event(fixture, launched, token: token, "running", native: cleared, hook: "SessionStart", source: "resume")

        // Chauffeur's Resume reopens the conversation that was active last.
        _ = try await fixture.stop()
        let ended = try await fixture.session()
        let arguments = try CLIAdapter.arguments(session: ended, endpoint: "", ctlPath: "/bin/false", integrationDirectory: fixture.root, coordination: false, resume: true)
        #expect(arguments.suffix(2) == ["--resume", cleared])
    }

    @Test func parallelStatusEventsCannotUndoAnAdoptedConversation() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let (launched, token) = try await launch(fixture, fixture.request)
        for round in 0..<5 {
            let cleared = UUID().uuidString.lowercased()
            let stale = try #require(try await fixture.session().nativeConversationID)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<12 {
                    group.addTask {
                        if index == 3 { _ = try await event(fixture, launched, token: token, "running", native: cleared, hook: "SessionStart", source: "clear") }
                        else { _ = try await event(fixture, launched, token: token, "running", native: stale, hook: "PostToolUse") }
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await fixture.session().nativeConversationID == cleared, "round \(round)")
        }
        _ = try await fixture.stop()
    }

    @Test func resumingAnotherLiveSessionsConversationAdoptsItWithAWarning() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let (first, token) = try await launch(fixture, fixture.request)
        var request = fixture.request; request.retryKey = UUID(); request.title = "Other window"; request.allowSharedCheckout = true
        let (second, _) = try await launch(fixture, request)
        let owned = try #require(second.nativeConversationID).lowercased()
        var session = try await event(fixture, first, token: token, "running", native: owned, hook: "SessionStart", source: "resume")
        #expect(session.nativeConversationID == owned)
        #expect(session.conversationWarning?.contains("Other window") == true)
        let errors = try await fixture.runtime.snapshot()["errors"].decode([ChauffeurError].self)
        #expect(errors.contains { $0.code == "conversation_in_use" })
        // Moving on to a conversation nobody else has clears the warning.
        session = try await event(fixture, first, token: token, "running", native: UUID().uuidString, hook: "SessionStart", source: "clear")
        #expect(session.conversationWarning == nil)
        for id in [first.id, second.id] {
            _ = try await fixture.runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(id.uuidString), "force": .bool(true)])))
        }
    }

    @Test func inboxHintsRequireTheSessionsProviderAndConversation() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let (launched, token) = try await launch(fixture, fixture.request)
        func hint(provider: String, native: String?) async throws -> InboxHintSummary {
            var params: [String: JSONValue] = ["token": .string(token), "provider": .string(provider), "event": .string("UserPromptSubmit")]
            if let native { params["nativeConversationID"] = .string(native) }
            return try await fixture.runtime.handle(IPCRequest("inboxHint", params: .object(params))).decode(InboxHintSummary.self)
        }
        await #expect(throws: ChauffeurError.self) { try await hint(provider: "codex", native: nil) }
        let peer = LedgerTests().session(project: launched.projectID, group: launched.groupID)
        try await fixture.runtime.ledger.register(peer)
        let sender = try await fixture.runtime.ledger.authenticate(fixture.runtime.ledger.issueGrant(sessionID: peer.id))
        _ = try await fixture.runtime.ledger.send(caller: sender, recipientID: launched.id, body: "Mail", retryKey: "mail")
        // Another conversation, or a hook without a usable ID, leaves the reminder for the session itself.
        #expect(try await hint(provider: "claude", native: UUID().uuidString) == InboxHintSummary())
        #expect(try await hint(provider: "claude", native: nil) == InboxHintSummary())
        #expect(try await hint(provider: "claude", native: launched.id.uuidString.lowercased()).count == 1)
        await #expect(throws: ChauffeurError.self) {
            _ = try await fixture.runtime.handle(IPCRequest("inboxHint", params: .object(["token": .string("forged"), "provider": .string("claude"), "event": .string("Stop")])))
        }
        _ = try await fixture.stop()
    }
}
