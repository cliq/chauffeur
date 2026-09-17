import Foundation
import Testing
import ChauffeurRemoteProtocol
import ChauffeurTerminalInterface
import ChauffeurTerminalTesting
@testable import ChauffeurRemoteClient

@MainActor
struct RemoteSessionControllerTests {
    private static let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    @MainActor
    private final class Harness {
        let pair = InMemoryTransportPair()
        let host: FakeHost
        let connection: RemoteConnection
        let adapter = FakeTerminalEngineAdapter()
        let controller: RemoteSessionController

        init(requestTimeout: Duration = .seconds(2)) {
            host = FakeHost(transport: pair.server)
            host.start()
            connection = RemoteConnection(transport: pair.client, requestTimeout: requestTimeout)
            controller = RemoteSessionController(sessionID: RemoteSessionControllerTests.sessionID, connection: connection, adapter: adapter)
        }

        func connect() async throws {
            _ = try await connection.connect(hello: Fixtures.hello())
        }

        func attachRequests() -> [AttachTerminalRequest] {
            host.requests(ofKind: "attachTerminal").compactMap {
                if case .attachTerminal(let request) = $0.operation { return request }
                return nil
            }
        }
    }

    private func makeAttached() async throws -> Harness {
        let harness = Harness()
        try await harness.connect()
        await harness.controller.attach(takeControl: false)
        #expect(harness.controller.state == .attached(generation: FakeHost.attachmentGeneration))
        return harness
    }

    @Test func attachResetsAdapterSendsCellSizeAndEnablesInput() async throws {
        let harness = Harness()
        try await harness.connect()
        harness.adapter.cellSize = TerminalCellSize(cols: 100, rows: 40)
        harness.adapter.setInputEnabled(false)

        await harness.controller.attach(takeControl: false)

        #expect(harness.adapter.resetCount == 1)
        #expect(harness.controller.state == .attached(generation: FakeHost.attachmentGeneration))
        #expect(harness.adapter.isInputEnabled)
        let attaches = harness.attachRequests()
        #expect(attaches == [AttachTerminalRequest(sessionID: Self.sessionID, takeControl: false, cols: 100, rows: 40)])
    }

    @Test func outputFramesFeedTheAdapterInOrder() async throws {
        let harness = try await makeAttached()

        await harness.host.pushOutput(sequence: 0, "a")
        await harness.host.pushOutput(sequence: 1, "b")
        await harness.host.pushOutput(sequence: 2, "c")

        #expect(await eventually { harness.adapter.fed.count == 3 })
        #expect(harness.adapter.screenText == "abc")
        #expect(harness.controller.state == .attached(generation: FakeHost.attachmentGeneration))
    }

    @Test func staleGenerationFramesAreDropped() async throws {
        let harness = try await makeAttached()

        await harness.host.pushOutput(generation: FakeHost.attachmentGeneration - 1, sequence: 0, "old")
        await harness.host.pushOutput(generation: FakeHost.attachmentGeneration + 1, sequence: 0, "future")
        await harness.host.pushOutput(sequence: 0, "live")

        #expect(await eventually { harness.adapter.fed.count == 1 })
        #expect(harness.controller.droppedStaleFrames == 2)
        #expect(harness.adapter.screenText == "live")
        #expect(harness.controller.state == .attached(generation: FakeHost.attachmentGeneration))
    }

    @Test func sequenceGapDisconnectsAndDisablesInput() async throws {
        let harness = try await makeAttached()

        await harness.host.pushOutput(sequence: 0, "a")
        await harness.host.pushOutput(sequence: 2, "c")

        #expect(await eventually { harness.controller.state == .disconnected(message: "Output stream lost bytes") })
        #expect(!harness.adapter.isInputEnabled)
        #expect(harness.adapter.screenText == "a")

        // A later in-order frame for the dead attachment is not rendered either.
        await harness.host.pushOutput(sequence: 3, "d")
        #expect(await eventually { harness.controller.droppedStaleFrames == 1 })
        #expect(harness.adapter.screenText == "a")
    }

    @Test func terminalBusyBecomesControlLostWithoutRetry() async throws {
        let harness = Harness()
        try await harness.connect()
        harness.host.responder = { request in
            if case .attachTerminal = request.operation {
                return RemoteResponse(id: request.id, error: RemoteError(code: "terminal_busy", message: "Desktop has control"))
            }
            return FakeHost.defaultResponse(for: request)
        }

        await harness.controller.attach(takeControl: false)
        #expect(harness.controller.state == .controlLost(message: "Desktop has control"))
        #expect(!harness.adapter.isInputEnabled)

        await harness.controller.handleForeground()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.attachRequests().count == 1)
    }

    @Test func attachmentEndedControlLostStopsInputAndForegroundDoesNotReattach() async throws {
        let harness = try await makeAttached()

        await harness.host.pushEvent(.attachmentEnded(generation: FakeHost.attachmentGeneration, reason: .controlLost, message: "Desktop took control"))

        #expect(await eventually { harness.controller.state == .controlLost(message: "Desktop took control") })
        #expect(!harness.adapter.isInputEnabled)

        await harness.controller.handleForeground()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.attachRequests().count == 1)
    }

    @Test func attachmentEndedForAnotherGenerationIsIgnored() async throws {
        let harness = try await makeAttached()

        await harness.host.pushEvent(.attachmentEnded(generation: FakeHost.attachmentGeneration + 3, reason: .controlLost, message: nil))
        await harness.host.pushOutput(sequence: 0, "still here")

        #expect(await eventually { harness.adapter.fed.count == 1 })
        #expect(harness.controller.state == .attached(generation: FakeHost.attachmentGeneration))
        #expect(harness.adapter.isInputEnabled)
    }

    @Test func slowConsumerEndDisconnectsAndForegroundReattaches() async throws {
        let harness = try await makeAttached()

        await harness.host.pushEvent(.attachmentEnded(generation: FakeHost.attachmentGeneration, reason: .slowConsumer, message: "Too slow"))
        #expect(await eventually { harness.controller.state == .disconnected(message: "Too slow") })
        #expect(!harness.adapter.isInputEnabled)

        await harness.controller.handleForeground()

        #expect(harness.controller.state == .attached(generation: FakeHost.attachmentGeneration))
        #expect(harness.attachRequests().count == 2)
        #expect(harness.attachRequests()[1].takeControl == false)
        #expect(harness.adapter.resetCount == 2)
    }

    @Test func sessionEndedBecomesEnded() async throws {
        let harness = try await makeAttached()

        await harness.host.pushEvent(.attachmentEnded(generation: FakeHost.attachmentGeneration, reason: .sessionEnded, message: nil))

        #expect(await eventually { harness.controller.state == .ended(reason: .sessionEnded) })
        #expect(!harness.adapter.isInputEnabled)
    }

    @Test func typedInputWhileAttachedIsSentWithTheGeneration() async throws {
        let harness = try await makeAttached()

        harness.adapter.simulateTypedInput(Data("ls\r".utf8))
        harness.adapter.simulateTypedInput(Data("pwd\r".utf8))

        #expect(await eventually { harness.host.inputFrames.count == 2 })
        let frames = harness.host.inputFrames
        #expect(frames.map(\.generation) == [FakeHost.attachmentGeneration, FakeHost.attachmentGeneration])
        #expect(frames.map(\.bytes) == [Data("ls\r".utf8), Data("pwd\r".utf8)])
    }

    @Test func typedInputWhileDisconnectedIsDropped() async throws {
        let harness = try await makeAttached()
        await harness.host.pushEvent(.attachmentEnded(generation: FakeHost.attachmentGeneration, reason: .transportClosed, message: nil))
        #expect(await eventually {
            if case .disconnected = harness.controller.state { return true }
            return false
        })

        // Through the adapter (its own gate) and straight into the delegate (the controller's gate).
        harness.adapter.simulateTypedInput(Data("x".utf8))
        harness.controller.terminal(harness.adapter, didGenerateInput: Data("y".utf8))
        try? await Task.sleep(for: .milliseconds(100))

        #expect(harness.host.inputFrames.isEmpty)

        // Nothing typed while disconnected is replayed after reattaching.
        await harness.controller.handleForeground()
        #expect(harness.controller.state == .attached(generation: FakeHost.attachmentGeneration))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.host.inputFrames.isEmpty)
    }

    @Test func rapidResizesAreCoalescedIntoOneRequest() async throws {
        let harness = try await makeAttached()

        harness.adapter.simulateResize(cols: 90, rows: 30)
        harness.adapter.simulateResize(cols: 95, rows: 32)
        harness.adapter.simulateResize(cols: 120, rows: 36)

        #expect(await eventually { harness.host.requests(ofKind: "terminalResize").count == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        let resizes = harness.host.requests(ofKind: "terminalResize")
        #expect(resizes.count == 1)
        if case .terminalResize(let request)? = resizes.first?.operation {
            #expect(request == TerminalResizeRequest(generation: FakeHost.attachmentGeneration, cols: 120, rows: 36))
        } else {
            Issue.record("expected a terminalResize request")
        }
    }

    @Test func resizeWhileNotAttachedIsNotSent() async throws {
        let harness = Harness()
        try await harness.connect()

        harness.adapter.simulateResize(cols: 50, rows: 20)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(harness.host.requests(ofKind: "terminalResize").isEmpty)
    }

    @Test func takeControlSendsAttachWithTakeControlTrue() async throws {
        let harness = Harness()
        try await harness.connect()
        let busy = LockedBox(true)
        harness.host.responder = { request in
            if case .attachTerminal(let attach) = request.operation, busy.value, !attach.takeControl {
                return RemoteResponse(id: request.id, error: RemoteError(code: "terminal_busy", message: "busy"))
            }
            return FakeHost.defaultResponse(for: request)
        }

        await harness.controller.attach(takeControl: false)
        #expect(harness.controller.state == .controlLost(message: "busy"))

        await harness.controller.takeControl()

        #expect(harness.controller.state == .attached(generation: FakeHost.attachmentGeneration))
        #expect(harness.adapter.isInputEnabled)
        #expect(harness.attachRequests().map(\.takeControl) == [false, true])
    }

    @Test func detachSendsGenerationAndGoesIdle() async throws {
        let harness = try await makeAttached()

        await harness.controller.detach()

        #expect(harness.controller.state == .idle)
        #expect(!harness.adapter.isInputEnabled)
        let detaches = harness.host.requests(ofKind: "detachTerminal")
        #expect(detaches.count == 1)
        if case .detachTerminal(let request)? = detaches.first?.operation {
            #expect(request.generation == FakeHost.attachmentGeneration)
        }
    }

    @Test func connectionClosedDisconnectsTheTerminal() async throws {
        let harness = try await makeAttached()

        harness.pair.closeBoth()

        #expect(await eventually {
            if case .disconnected = harness.controller.state { return true }
            return false
        })
        #expect(!harness.adapter.isInputEnabled)
    }

    @Test func outputArrivingBeforeAttachResponseIsHandledIsNotLost() async throws {
        let harness = Harness()
        try await harness.connect()
        // The host answers the attach and immediately follows with the first screen redraw.
        harness.host.responder = { request in
            if case .attachTerminal = request.operation { return nil }
            return FakeHost.defaultResponse(for: request)
        }
        let attach = Task { await harness.controller.attach(takeControl: false) }
        #expect(await eventually { harness.attachRequests().count == 1 })
        let id = harness.host.requests(ofKind: "attachTerminal")[0].id
        let info = AttachmentInfo(generation: FakeHost.attachmentGeneration, sessionID: Self.sessionID, cols: 80, rows: 24)
        await harness.host.respond(to: id, result: .attachment(info))
        await harness.host.pushOutput(sequence: 0, "first screen")
        await attach.value

        #expect(await eventually { harness.adapter.screenText == "first screen" })
        #expect(harness.controller.droppedStaleFrames == 0)
    }
}
