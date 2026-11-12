import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// A conversation from the checkout's Recent Conversations resumes as a new session.
struct ConversationResumeLaunchTests {
    @Test func resumingRecordsTheConversationAndStartsTheProviderResume() async throws {
        let fixture = try await LaunchFixture.make(kind: .opencode); defer { fixture.cleanup() }
        let conversation = "ses_0123456789abcdefghijABCDEF"
        var request = fixture.request; request.resumeConversationID = conversation
        let launched = try await fixture.runtime.launch(request)
        #expect(launched.nativeConversationID == conversation)
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("launch-record").path) }
        let record = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: fixture.path("launch-record")))
        #expect(record["argv"] == .array([.string("-s"), .string(conversation)]))
        _ = try await fixture.stop()
    }

    @Test func claudeResumeKeepsTheConversationInsteadOfAssigningANewOne() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let conversation = UUID().uuidString.lowercased()
        var request = fixture.request; request.resumeConversationID = conversation
        let launched = try await fixture.runtime.launch(request)
        #expect(launched.nativeConversationID == conversation)
        let arguments = try CLIAdapter.arguments(session: launched, endpoint: "", ctlPath: "/bin/false", integrationDirectory: fixture.root, coordination: false, resume: true)
        #expect(arguments.suffix(2) == ["--resume", conversation])
        _ = try await fixture.stop()
    }

    @Test func aConversationAlreadyRunningCannotResumeTwice() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let first = try await fixture.runtime.launch(fixture.request)
        var request = fixture.request; request.retryKey = UUID(); request.allowSharedCheckout = true
        request.resumeConversationID = try #require(first.nativeConversationID)
        await #expect { _ = try await fixture.runtime.launch(request) } throws: { ($0 as? ChauffeurError)?.code == "conversation_in_use" }
        // Refused before a session record exists.
        let sessions = try await fixture.runtime.snapshot()["sessions"].decode([Session].self)
        #expect(!sessions.contains { $0.id == request.retryKey })
        _ = try await fixture.stop()
    }

    @Test func concurrentResumesOfOneConversationStartOnlyOneSession() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let conversation = UUID().uuidString
        func request() -> LaunchRequest {
            var request = fixture.request; request.retryKey = UUID(); request.allowSharedCheckout = true; request.resumeConversationID = conversation
            return request
        }
        let (first, second) = (request(), request())
        func attempt(_ request: LaunchRequest) async -> (Session?, String?) {
            do { return (try await fixture.runtime.launch(request), nil) } catch { return (nil, (error as? ChauffeurError)?.code) }
        }
        async let a = attempt(first)
        async let b = attempt(second)
        let results = await [a, b]
        #expect(results.compactMap(\.0).count == 1)
        #expect(results.contains { $0.1 == "conversation_in_use" })
        for session in results.compactMap(\.0) {
            _ = try await fixture.runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(session.id.uuidString), "force": .bool(true)])))
        }
    }

    @Test func anEndedSessionCannotResumeAConversationAnotherSessionContinues() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let original = try await fixture.runtime.launch(fixture.request)
        _ = try await fixture.runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(original.id.uuidString), "force": .bool(true)])))
        try await fixture.wait { try await !fixture.session().state.isLive }
        var request = fixture.request; request.retryKey = UUID(); request.resumeConversationID = try #require(original.nativeConversationID)
        let continued = try await fixture.runtime.launch(request)
        await #expect { _ = try await fixture.runtime.handle(IPCRequest("resume", params: .object(["sessionID": .string(original.id.uuidString)]))) }
            throws: { ($0 as? ChauffeurError)?.code == "conversation_in_use" }
        _ = try await fixture.runtime.handle(IPCRequest("stop", params: .object(["sessionID": .string(continued.id.uuidString), "force": .bool(true)])))
    }

    @Test func invalidResumeRequestsAreRefusedBeforeLaunching() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        func refused(_ change: (inout LaunchRequest) -> Void) async throws {
            var request = fixture.request; request.retryKey = UUID(); change(&request)
            await #expect { _ = try await fixture.runtime.launch(request) } throws: { ($0 as? ChauffeurError)?.code == "invalid_argument" }
            let sessions = try await fixture.runtime.snapshot()["sessions"].decode([Session].self)
            #expect(!sessions.contains { $0.id == request.retryKey })
        }
        // An OpenCode ID is not a Claude Code conversation.
        try await refused { $0.resumeConversationID = "ses_0123456789abcdefghijABCDEF" }
        try await refused { $0.resumeConversationID = UUID().uuidString; $0.task = "Start over" }
        try await refused { request in
            request = .shell(projectID: request.projectID, groupID: request.groupID, folderID: request.folderID, title: "Shell", retryKey: request.retryKey)
            request.resumeConversationID = UUID().uuidString
        }
    }

    @Test func requestsWithoutAResumeKeepTheirFingerprint() throws {
        let request = LaunchRequest(projectID: UUID(), groupID: UUID(), presetID: UUID(), folderID: UUID(), title: "Fixture")
        let encoded = try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(request))
        guard case .object(let fields) = encoded else { Issue.record("Expected an object"); return }
        #expect(fields["resumeConversationID"] == nil)
        #expect(try JSONCoding.decode(LaunchRequest.self, from: JSONCoding.encode(request)).resumeConversationID == nil)
    }
}
