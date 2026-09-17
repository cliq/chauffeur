import Foundation
import Testing
@testable import ChauffeurRemoteProtocol

struct EnvelopeTests {

    // MARK: - Fixtures

    private static let sessionSummary = SessionSummary(
        id: UUID(),
        projectID: UUID(),
        folderID: UUID(),
        title: "Fix crash",
        kind: .codex,
        state: .running,
        checkoutPath: "/tmp/checkout",
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )

    private static let operationStatus = OperationStatus(
        operationKey: UUID(),
        phase: .launching,
        updatedAt: Date(timeIntervalSince1970: 3_000)
    )

    private static let launchSpec = LaunchSpec(projectID: UUID(), folderID: UUID())

    private static func remoteOperationCases() -> [RemoteOperation] {
        [
            .hello(HelloRequest(deviceID: UUID(), deviceToken: "tok", clientName: "iPhone", clientVersion: "1.0", protocolVersion: 1)),
            .pair(PairRequest(deviceName: "iPhone", protocolVersion: 1)),
            .listInventory(ListInventoryRequest(sinceRevision: 5)),
            .previewWorktreeDestination(PreviewWorktreeRequest(projectID: UUID(), folderID: UUID(), branch: "feature/x")),
            .launch(LaunchOperationRequest(operationKey: UUID(), fingerprint: "abc", launch: launchSpec)),
            .getOperationStatus(OperationStatusRequest(operationKey: UUID())),
            .attachTerminal(AttachTerminalRequest(sessionID: UUID(), cols: 80, rows: 24)),
            .terminalResize(TerminalResizeRequest(generation: 1, cols: 80, rows: 24)),
            .detachTerminal(DetachTerminalRequest(generation: 1))
        ]
    }

    private static func remoteResultCases() -> [RemoteResult] {
        [
            .hostInfo(HostInfo(hostID: UUID(), hostName: "Mac", runtimeVersion: "1.0", build: "100", protocolVersion: 1)),
            .pairing(PairingResult(remoteAccessKey: Data([1, 2, 3]), deviceID: UUID(), deviceToken: "tok", mainPort: 4000, hostID: UUID(), hostName: "Mac")),
            .inventory(InventorySnapshot(revision: 1, hostName: "Mac", generatedAt: Date(timeIntervalSince1970: 4_000))),
            .worktreeDestination(WorktreeDestinationPreview(path: "/tmp/wt")),
            .operation(operationStatus),
            .attachment(AttachmentInfo(generation: 1, sessionID: UUID(), cols: 80, rows: 24)),
            .ack
        ]
    }

    private static func remoteEventCases() -> [RemoteEvent] {
        [
            .inventoryChanged(revision: 9),
            .sessionChanged(sessionSummary),
            .attachmentEnded(generation: 2, reason: .slowConsumer, message: "too slow"),
            .attachmentEnded(generation: 2, reason: .revoked, message: nil),
            .operationUpdated(operationStatus),
            .accessRevoked
        ]
    }

    // MARK: - Round trips

    @Test(arguments: remoteOperationCases())
    func remoteOperationRoundTrips(operation: RemoteOperation) throws {
        let data = try RemoteJSON.encode(operation)
        let decoded = try RemoteJSON.decode(RemoteOperation.self, from: data)
        #expect(decoded == operation)
    }

    @Test(arguments: remoteResultCases())
    func remoteResultRoundTrips(result: RemoteResult) throws {
        let data = try RemoteJSON.encode(result)
        let decoded = try RemoteJSON.decode(RemoteResult.self, from: data)
        #expect(decoded == result)
    }

    @Test(arguments: remoteEventCases())
    func remoteEventRoundTrips(event: RemoteEvent) throws {
        let data = try RemoteJSON.encode(event)
        let decoded = try RemoteJSON.decode(RemoteEvent.self, from: data)
        #expect(decoded == event)
    }

    // MARK: - Wire "kind" strings

    private static func kindString(from data: Data) throws -> String {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["kind"] as? String)
    }

    @Test(arguments: zip(
        remoteOperationCases(),
        [
            "hello", "pair", "listInventory", "previewWorktreeDestination", "launch",
            "getOperationStatus", "attachTerminal", "terminalResize", "detachTerminal"
        ]
    ))
    func remoteOperationKindStrings(operation: RemoteOperation, expectedKind: String) throws {
        let data = try RemoteJSON.encode(operation)
        #expect(try Self.kindString(from: data) == expectedKind)
        #expect(operation.kind == expectedKind)
    }

    @Test(arguments: zip(
        remoteResultCases(),
        ["hostInfo", "pairing", "inventory", "worktreeDestination", "operation", "attachment", "ack"]
    ))
    func remoteResultKindStrings(result: RemoteResult, expectedKind: String) throws {
        let data = try RemoteJSON.encode(result)
        #expect(try Self.kindString(from: data) == expectedKind)
        #expect(result.kind == expectedKind)
    }

    @Test(arguments: zip(
        remoteEventCases(),
        ["inventoryChanged", "sessionChanged", "attachmentEnded", "attachmentEnded", "operationUpdated", "accessRevoked"]
    ))
    func remoteEventKindStrings(event: RemoteEvent, expectedKind: String) throws {
        let data = try RemoteJSON.encode(event)
        #expect(try Self.kindString(from: data) == expectedKind)
    }

    // MARK: - Unknown kind

    @Test func unknownOperationKindFailsToDecode() {
        let json = Data(#"{"kind":"doesNotExist","payload":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try RemoteJSON.decode(RemoteOperation.self, from: json)
        }
    }

    @Test func unknownResultKindFailsToDecode() {
        let json = Data(#"{"kind":"doesNotExist","payload":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try RemoteJSON.decode(RemoteResult.self, from: json)
        }
    }

    @Test func unknownEventKindFailsToDecode() {
        let json = Data(#"{"kind":"doesNotExist","payload":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try RemoteJSON.decode(RemoteEvent.self, from: json)
        }
    }

    // MARK: - RemoteRequest / RemoteResponse / RemoteError

    @Test func remoteRequestDefaultProtocolVersionIsOne() {
        let request = RemoteRequest(operation: .pair(PairRequest(deviceName: "iPhone", protocolVersion: 1)))
        #expect(request.protocolVersion == 1)
    }

    @Test func remoteErrorConformsToErrorAndRoundTrips() throws {
        let error = RemoteError(code: "not_found", message: "Session missing", retryable: true)
        let data = try RemoteJSON.encode(error)
        let decoded = try RemoteJSON.decode(RemoteError.self, from: data)
        #expect(decoded == error)

        let thrown: any Error = error
        #expect((thrown as? RemoteError) == error)
    }

    @Test func remoteResponseRoundTripsWithResultOrError() throws {
        let resultResponse = RemoteResponse(id: UUID(), result: .ack)
        let resultData = try RemoteJSON.encode(resultResponse)
        let decodedResult = try RemoteJSON.decode(RemoteResponse.self, from: resultData)
        #expect(decodedResult == resultResponse)

        let errorResponse = RemoteResponse(id: UUID(), error: RemoteError(code: "boom", message: "bad"))
        let errorData = try RemoteJSON.encode(errorResponse)
        let decodedError = try RemoteJSON.decode(RemoteResponse.self, from: errorData)
        #expect(decodedError == errorResponse)
    }

    // MARK: - Fingerprint

    @Test func computeFingerprintIsStableForIdenticalInputs() {
        let worktree = WorktreeCreationSpec(branch: "feature/x", baseRef: "main")
        let launch = LaunchSpec(projectID: UUID(), folderID: UUID())

        let first = LaunchOperationRequest.computeFingerprint(newWorktree: worktree, launch: launch)
        let second = LaunchOperationRequest.computeFingerprint(newWorktree: worktree, launch: launch)
        #expect(first == second)
    }

    @Test func computeFingerprintDiffersWhenBranchChanges() {
        let launch = LaunchSpec(projectID: UUID(), folderID: UUID())
        let worktreeA = WorktreeCreationSpec(branch: "feature/a", baseRef: "main")
        let worktreeB = WorktreeCreationSpec(branch: "feature/b", baseRef: "main")

        let fingerprintA = LaunchOperationRequest.computeFingerprint(newWorktree: worktreeA, launch: launch)
        let fingerprintB = LaunchOperationRequest.computeFingerprint(newWorktree: worktreeB, launch: launch)
        #expect(fingerprintA != fingerprintB)
    }
}
