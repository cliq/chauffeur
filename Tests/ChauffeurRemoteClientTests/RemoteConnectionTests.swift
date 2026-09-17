import Foundation
import Testing
import ChauffeurRemoteProtocol
@testable import ChauffeurRemoteClient

@MainActor
struct RemoteConnectionTests {
    private struct Harness {
        let pair = InMemoryTransportPair()
        let host: FakeHost
        let connection: RemoteConnection

        init(requestTimeout: Duration = .seconds(2), byteByByte: Bool = false) {
            host = FakeHost(transport: pair.server)
            host.sendByteByByte = byteByByte
            host.start()
            connection = RemoteConnection(transport: pair.client, requestTimeout: requestTimeout)
        }
    }

    @Test func helloRoundTripBecomesReady() async throws {
        let harness = Harness()
        let info = try await harness.connection.connect(hello: Fixtures.hello())

        #expect(info.hostName == "fake-mac")
        #expect(await harness.connection.state == .ready(info))
        let hellos = harness.host.requests(ofKind: "hello")
        #expect(hellos.count == 1)
        if case .hello(let hello)? = hellos.first?.operation {
            #expect(hello.deviceID == Fixtures.hello().deviceID)
        } else {
            Issue.record("expected a hello request")
        }
    }

    @Test func protocolMismatchErrorFromHost() async throws {
        let harness = Harness()
        harness.host.responder = { request in
            RemoteResponse(id: request.id, error: RemoteError(code: "protocol_mismatch", message: "Host speaks protocol version 3"))
        }

        await #expect(throws: RemoteClientError.protocolMismatch(hostVersion: 3, clientVersion: RemoteProtocol.version)) {
            try await harness.connection.connect(hello: Fixtures.hello())
        }
        #expect(await harness.connection.state == .failed(.protocolMismatch(hostVersion: 3, clientVersion: RemoteProtocol.version)))
    }

    @Test func mismatchedHostInfoVersionIsProtocolMismatch() async throws {
        let harness = Harness()
        harness.host.responder = { request in
            RemoteResponse(id: request.id, result: .hostInfo(FakeHost.hostInfo(protocolVersion: RemoteProtocol.version + 1)))
        }

        await #expect(throws: RemoteClientError.protocolMismatch(hostVersion: RemoteProtocol.version + 1, clientVersion: RemoteProtocol.version)) {
            try await harness.connection.connect(hello: Fixtures.hello())
        }
    }

    @Test func unauthorizedHello() async throws {
        let harness = Harness()
        harness.host.responder = { request in
            RemoteResponse(id: request.id, error: RemoteError(code: "device_revoked", message: "Device revoked"))
        }

        await #expect(throws: RemoteClientError.unauthorized("Device revoked")) {
            try await harness.connection.connect(hello: Fixtures.hello())
        }
        #expect(await harness.connection.state == .failed(.unauthorized("Device revoked")))
    }

    @Test func overlappingRequestsAreCorrelatedWhenAnsweredOutOfOrder() async throws {
        let harness = Harness()
        harness.host.responder = { request in
            if case .hello = request.operation { return FakeHost.defaultResponse(for: request) }
            return nil
        }
        _ = try await harness.connection.connect(hello: Fixtures.hello())

        let first = Task { try await harness.connection.request(.listInventory(ListInventoryRequest())) }
        let second = Task {
            try await harness.connection.request(.previewWorktreeDestination(PreviewWorktreeRequest(projectID: UUID(), folderID: UUID(), branch: "b")))
        }
        #expect(await eventually { harness.host.requests.count == 3 })

        let inventoryID = harness.host.requests(ofKind: "listInventory")[0].id
        let previewID = harness.host.requests(ofKind: "previewWorktreeDestination")[0].id
        await harness.host.respond(to: previewID, result: .worktreeDestination(WorktreeDestinationPreview(path: "/preview")))
        await harness.host.respond(to: inventoryID, result: .inventory(FakeHost.inventory(revision: 42)))

        #expect(try await first.value == .inventory(FakeHost.inventory(revision: 42)))
        #expect(try await second.value == .worktreeDestination(WorktreeDestinationPreview(path: "/preview")))
    }

    @Test func requestTimesOutAndLateResponseIsIgnored() async throws {
        let harness = Harness(requestTimeout: .milliseconds(150))
        harness.host.responder = { request in
            if case .listInventory = request.operation { return nil }
            return FakeHost.defaultResponse(for: request)
        }
        let info = try await harness.connection.connect(hello: Fixtures.hello())

        await #expect(throws: RemoteClientError.timeout) {
            try await harness.connection.request(.listInventory(ListInventoryRequest()))
        }
        // A timeout does not take the connection down.
        #expect(await harness.connection.state == .ready(info))

        let lateID = harness.host.requests(ofKind: "listInventory")[0].id
        await harness.host.respond(to: lateID, result: .inventory(FakeHost.inventory()))
        let result = try await harness.connection.request(.previewWorktreeDestination(PreviewWorktreeRequest(projectID: UUID(), folderID: UUID(), branch: "x")))
        #expect(result == .worktreeDestination(WorktreeDestinationPreview(path: "/tmp/worktrees/x")))
    }

    @Test func pingIsAnsweredWithPongCarryingThePayload() async throws {
        let harness = Harness()
        _ = try await harness.connection.connect(hello: Fixtures.hello())

        await harness.host.ping(Data([1, 2, 3]))

        #expect(await eventually { harness.host.pongs == [Data([1, 2, 3])] })
    }

    @Test func framingErrorFailsTheConnection() async throws {
        let harness = Harness()
        _ = try await harness.connection.connect(hello: Fixtures.hello())
        let states = await harness.connection.stateChanges()

        await harness.host.sendRaw(Data([9, 1, 0, 0, 0, 0, 0, 0])) // unsupported frame version

        var sawFailure = false
        for await state in states {
            if case .failed(.framing) = state {
                sawFailure = true
                break
            }
        }
        #expect(sawFailure)
        await #expect(throws: RemoteClientError.self) {
            try await harness.connection.request(.listInventory(ListInventoryRequest()))
        }
    }

    @Test func framesSplitAtEveryByteStillDecode() async throws {
        let harness = Harness(byteByByte: true)
        let events = await harness.connection.events()
        let info = try await harness.connection.connect(hello: Fixtures.hello())
        #expect(info.protocolVersion == RemoteProtocol.version)

        let result = try await harness.connection.request(.listInventory(ListInventoryRequest()))
        #expect(result == .inventory(FakeHost.inventory()))

        await harness.host.pushEvent(.inventoryChanged(revision: 9))
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .inventoryChanged(revision: 9))
    }

    @Test func transportClosedFailsPendingRequestsAndClosesState() async throws {
        let harness = Harness()
        harness.host.responder = { request in
            if case .listInventory = request.operation { return nil }
            return FakeHost.defaultResponse(for: request)
        }
        _ = try await harness.connection.connect(hello: Fixtures.hello())

        let pending = Task { try await harness.connection.request(.listInventory(ListInventoryRequest())) }
        #expect(await eventually { harness.host.requests(ofKind: "listInventory").count == 1 })

        harness.pair.closeBoth()

        await #expect(throws: RemoteClientError.disconnected) { try await pending.value }
        #expect(await eventually { true })
        #expect(await harness.connection.state == .closed)
        await #expect(throws: RemoteClientError.disconnected) {
            try await harness.connection.request(.listInventory(ListInventoryRequest()))
        }
    }

    @Test func transportFailureBeforeReadySurfacesFromConnect() async throws {
        let pair = InMemoryTransportPair()
        let connection = RemoteConnection(transport: pair.client)
        let task = Task { try await connection.connect(hello: Fixtures.hello()) }
        // The server end never starts; the client end is told the handshake failed.
        pair.failClient(.authenticationFailed)

        await #expect(throws: RemoteClientError.authenticationFailed) { try await task.value }
        #expect(await connection.state == .failed(.authenticationFailed))
    }

    @Test func closeFinishesSubscribersAndRejectsRequests() async throws {
        let harness = Harness()
        _ = try await harness.connection.connect(hello: Fixtures.hello())
        let states = await harness.connection.stateChanges()

        await harness.connection.close()

        var collected: [RemoteConnection.State] = []
        for await state in states { collected.append(state) }
        #expect(collected.last == .closed)
        await #expect(throws: RemoteClientError.disconnected) {
            try await harness.connection.sendTerminalInput(generation: 1, bytes: Data("x".utf8))
        }
    }

    @Test func terminalInputIsChunkedAtTheProtocolLimit() async throws {
        let harness = Harness()
        _ = try await harness.connection.connect(hello: Fixtures.hello())

        let bytes = Data(repeating: 0x41, count: RemoteFraming.maxTerminalChunkBytes + 10)
        try await harness.connection.sendTerminalInput(generation: 5, bytes: bytes)

        #expect(await eventually { harness.host.inputFrames.count == 2 })
        let frames = harness.host.inputFrames
        #expect(frames.map(\.generation) == [5, 5])
        #expect(frames[0].bytes.count == RemoteFraming.maxTerminalChunkBytes)
        #expect(frames[1].bytes.count == 10)
    }
}
