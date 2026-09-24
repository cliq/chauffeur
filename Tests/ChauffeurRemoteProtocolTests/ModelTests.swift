import Foundation
import Testing
@testable import ChauffeurRemoteProtocol

struct ModelTests {
    @Test func unknownSessionKindsDecodeAsAGenericAgent() throws {
        #expect(try RemoteJSON.decode(RemoteSessionKind.self, from: Data(#""gemini""#.utf8)) == .agent)
        #expect(try RemoteJSON.decode(RemoteSessionKind.self, from: Data(#""opencode""#.utf8)) == .opencode)
        #expect(String(decoding: try RemoteJSON.encode(RemoteSessionKind.opencode), as: UTF8.self) == #""opencode""#)
        let session = SessionSummary(id: UUID(), projectID: UUID(), folderID: UUID(), title: "Task", kind: .claude, state: .running, checkoutPath: "/repo", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        let newer = String(decoding: try RemoteJSON.encode(session), as: UTF8.self).replacingOccurrences(of: #""claude""#, with: #""gemini""#)
        #expect(try RemoteJSON.decode(SessionSummary.self, from: Data(newer.utf8)).kind == .agent)
    }

    @Test func clientsWithoutOpenSessionKindsSeeUnknownKindsAsShell() throws {
        #expect(RemoteProtocol.capabilities.contains(RemoteProtocol.openSessionKinds))
        let date = Date(timeIntervalSince1970: 0)
        func session(_ kind: RemoteSessionKind) -> SessionSummary {
            SessionSummary(id: UUID(), projectID: UUID(), folderID: UUID(), title: "Task", kind: kind, state: .running, checkoutPath: "/repo", createdAt: date, updatedAt: date)
        }
        let presets = [PresetSummary(id: UUID(), name: "OpenCode", kind: .opencode), PresetSummary(id: UUID(), name: "Claude", kind: .claude)]
        let project = ProjectSummary(id: UUID(), name: "P", archived: false, groups: [], presets: presets, folders: [])
        let inventory = InventorySnapshot(revision: 3, hostName: "Mac", projects: [project], sessions: [session(.opencode), session(.agent), session(.codex), session(.shell)], generatedAt: date)

        #expect(inventory.compatible(withClientCapabilities: RemoteProtocol.capabilities) == inventory)
        let legacy = inventory.compatible(withClientCapabilities: ["terminal.binary.v1", "launch.worktree.v1", "inventory.v1", "progress.v1"])
        #expect(legacy.sessions.map(\.kind) == [.shell, .shell, .codex, .shell])
        #expect(legacy.projects[0].presets.map(\.kind) == [.shell, .claude])
        #expect(legacy.revision == 3 && legacy.sessions.map(\.id) == inventory.sessions.map(\.id))
        // What an old build decodes: its strict enum knows only these kinds.
        enum StrictKind: String, Decodable { case codex, claude, shell }
        struct StrictSession: Decodable { var kind: StrictKind }
        struct StrictPreset: Decodable { var kind: StrictKind }
        struct StrictProject: Decodable { var presets: [StrictPreset] }
        struct StrictInventory: Decodable { var projects: [StrictProject]; var sessions: [StrictSession] }
        #expect(throws: (any Error).self) { try RemoteJSON.decode(StrictInventory.self, from: RemoteJSON.encode(inventory)) }
        #expect(try RemoteJSON.decode(StrictInventory.self, from: RemoteJSON.encode(legacy)).sessions.count == 4)
    }

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
