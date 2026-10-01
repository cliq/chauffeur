import Foundation
import Testing
import ChauffeurRemoteProtocol
import ChauffeurTerminalTesting
@testable import ChauffeurRemoteClient

@MainActor
struct RemoteHostSessionTests {
    /// Hands out a fresh in-memory pair and fake host for every connection the session opens.
    @MainActor
    private final class HostFactory {
        private(set) var pairs: [InMemoryTransportPair] = []
        private(set) var hosts: [FakeHost] = []
        var configure: (FakeHost) -> Void = { _ in }

        func makeConnection(_ savedHost: SavedHost) -> RemoteConnection {
            let pair = InMemoryTransportPair()
            let host = FakeHost(transport: pair.server)
            configure(host)
            host.start()
            pairs.append(pair)
            hosts.append(host)
            return RemoteConnection(transport: pair.client, requestTimeout: .seconds(2))
        }
    }

    private func makeSession(journal: InMemoryOperationJournal = InMemoryOperationJournal()) -> (RemoteHostSession, HostFactory) {
        let factory = HostFactory()
        let session = RemoteHostSession(host: Fixtures.savedHost(), journal: journal, makeConnection: { factory.makeConnection($0) })
        return (session, factory)
    }

    @Test func helloAdvertisesThatEverySessionKindDecodes() async throws {
        let (session, factory) = makeSession()
        await session.connect()
        let hello = try #require(factory.hosts.first?.requests(ofKind: "hello").first)
        guard case .hello(let request) = hello.operation else { Issue.record("Missing hello"); return }
        #expect(request.capabilities.contains(RemoteProtocol.openSessionKinds))
        session.disconnect()
    }

    @Test func progressUsesSessionIdentityAndRejectsMismatchedResponses() async throws {
        let (session, factory) = makeSession()
        let id = UUID()
        let panel = SessionProgressPanel(sessionID: id, summary: SessionProgressSummary(title: "Task", now: "Building", percentComplete: 20), json: "{}", html: "<html>Panel</html>")
        factory.configure = { host in
            host.responder = { request in
                if case .getSessionProgress = request.operation {
                    return RemoteResponse(id: request.id, result: .sessionProgress(panel))
                }
                return FakeHost.defaultResponse(for: request)
            }
        }
        await session.connect()
        #expect(try await session.sessionProgress(sessionID: id) == panel)
        await #expect(throws: RemoteClientError.self) { try await session.sessionProgress(sessionID: UUID()) }
        session.disconnect()
    }

    @Test func olderHostsGetAnUpdateMessageWithoutUnsupportedRequests() async throws {
        let (session, factory) = makeSession()
        factory.configure = { host in
            host.responder = { request in
                if case .hello = request.operation {
                    var info = FakeHost.hostInfo(); info.capabilities = ["inventory.v1"]
                    return RemoteResponse(id: request.id, result: .hostInfo(info))
                }
                return FakeHost.defaultResponse(for: request)
            }
        }
        await session.connect()
        await #expect(throws: RemoteClientError.self) { try await session.sessionProgress(sessionID: UUID()) }
        #expect(factory.hosts[0].requests(ofKind: "getSessionProgress").isEmpty)
        #expect(!session.isKeepAwakeSupported)
        await #expect(throws: RemoteClientError.self) {
            try await session.setKeepAwakeSettings(KeepAwakeSettings(automatic: true))
        }
        #expect(factory.hosts[0].requests(ofKind: "setKeepAwakeSettings").isEmpty)
        #expect(!session.isFileUploadSupported)
        await #expect(throws: RemoteClientError.self) { _ = try await session.uploadFile(Data([1]), filename: "a.png") }
        #expect(factory.hosts[0].requests(ofKind: "uploadFileChunk").isEmpty)
        #expect(!session.isTicketResolutionSupported)
        #expect(try await session.resolveTicket(projectID: UUID(), folderID: UUID(), text: "https://acme.atlassian.net/browse/MBL-1") == nil)
        #expect(factory.hosts[0].requests(ofKind: "resolveTicket").isEmpty)
        session.disconnect()
    }

    @Test func ticketsResolveOnTheMac() async throws {
        let (session, factory) = makeSession()
        await session.connect()
        defer { session.disconnect() }
        let link = "https://acme.atlassian.net/browse/MBL-1"
        #expect(try await session.resolveTicket(projectID: UUID(), folderID: UUID(), text: link)?.branch == "feat/mbl-1")
        #expect(try await session.resolveTicket(projectID: UUID(), folderID: UUID(), text: "Fix login") == nil)
        #expect(factory.hosts[0].requests(ofKind: "resolveTicket").count == 2)
    }

    @Test func filesUploadInOrderedChunksAndReturnTheMacPath() async throws {
        let (session, factory) = makeSession()
        await session.connect()
        defer { session.disconnect() }
        let data = Data(repeating: 7, count: UploadFileChunkRequest.chunkBytes * 2 + 10)
        var fractions: [Double] = []
        let path = try await session.uploadFile(data, filename: "screenshot.png") { fractions.append($0) }
        #expect(path == "/tmp/chauffeur-uploads/screenshot.png")
        let chunks = factory.hosts[0].requests(ofKind: "uploadFileChunk").compactMap { request -> UploadFileChunkRequest? in
            if case .uploadFileChunk(let chunk) = request.operation { return chunk }
            return nil
        }
        #expect(chunks.map(\.offset) == [0, Int64(UploadFileChunkRequest.chunkBytes), Int64(UploadFileChunkRequest.chunkBytes * 2)])
        #expect(Set(chunks.map(\.uploadID)).count == 1 && chunks.allSatisfy { $0.totalBytes == Int64(data.count) })
        #expect(chunks.reduce(Data()) { $0 + $1.data } == data)
        #expect(fractions.last == 1)
    }

    @Test func keepAwakeMutationDoesNotMarkStaleInventoryFresh() async throws {
        let (session, factory) = makeSession()
        await session.connect()
        defer { session.disconnect() }
        factory.hosts[0].responder = { request in
            if case .listInventory = request.operation {
                return RemoteResponse(id: request.id, error: RemoteError(code: "unavailable", message: "Inventory unavailable"))
            }
            return FakeHost.defaultResponse(for: request)
        }
        await session.refreshInventory()
        #expect(session.inventoryIsStale)
        try await session.setKeepAwakeSettings(.init(automatic: true))
        #expect(session.inventoryIsStale)
    }

    @Test func keepAwakeMutationsUseAbsoluteRequestsAndUpdateInventoryStatus() async throws {
        let (session, factory) = makeSession()
        let timerEnd = Date(timeIntervalSince1970: 8_000)
        let settingsStatus = KeepAwakeStatus(settings: KeepAwakeSettings(automatic: true, waitingMinutes: 45), qualifyingAgents: 2, assertionHeld: true)
        let timerStatus = KeepAwakeStatus(settings: settingsStatus.settings, manualUntil: timerEnd, qualifyingAgents: 2, assertionHeld: true)
        factory.configure = { host in
            host.responder = { request in
                switch request.operation {
                case .setKeepAwakeSettings(let settings):
                    #expect(settings == settingsStatus.settings)
                    return RemoteResponse(id: request.id, result: .keepAwake(settingsStatus))
                case .setKeepAwakeTimer(let timer):
                    #expect(timer.until == timerEnd)
                    return RemoteResponse(id: request.id, result: .keepAwake(timerStatus))
                default:
                    return FakeHost.defaultResponse(for: request)
                }
            }
        }
        await session.connect()
        #expect(session.isKeepAwakeSupported)

        try await session.setKeepAwakeSettings(settingsStatus.settings)
        #expect(session.inventory?.keepAwake == settingsStatus)
        try await session.setKeepAwakeTimer(until: timerEnd)
        #expect(session.inventory?.keepAwake == timerStatus)

        #expect(factory.hosts[0].requests(ofKind: "setKeepAwakeSettings").count == 1)
        #expect(factory.hosts[0].requests(ofKind: "setKeepAwakeTimer").count == 1)
        session.disconnect()
    }

    @Test func connectSendsHelloWithSavedCredentialsAndLoadsInventory() async throws {
        let (session, factory) = makeSession()

        await session.connect()

        #expect(session.connectionState == .connected(FakeHost.hostInfo()))
        #expect(session.inventory == FakeHost.inventory())
        #expect(!session.inventoryIsStale)
        let hellos = factory.hosts[0].requests(ofKind: "hello")
        if case .hello(let hello)? = hellos.first?.operation {
            #expect(hello.deviceID == Fixtures.savedHost().deviceID)
            #expect(hello.deviceToken == Fixtures.savedHost().deviceToken)
        } else {
            Issue.record("expected a hello request")
        }
    }

    @Test func launchRecordsTheKeyBeforeSendingAndClearsItOnCompleted() async throws {
        let journal = InMemoryOperationJournal()
        let (session, factory) = makeSession(journal: journal)
        let keysSeenByHost = LockedBox<[UUID]>([])
        factory.configure = { host in
            host.responder = { request in
                if case .launch = request.operation {
                    keysSeenByHost.value = journal.pendingKeys()
                }
                return FakeHost.defaultResponse(for: request)
            }
        }
        await session.connect()

        let request = Fixtures.launchRequest()
        let status = try await session.launch(request)

        #expect(status.phase == .completed)
        #expect(keysSeenByHost.value == [request.operationKey])
        #expect(journal.pendingKeys().isEmpty)
    }

    @Test func lostLaunchResponseKeepsTheKeyAndReconcileQueriesItAfterReconnect() async throws {
        let journal = InMemoryOperationJournal()
        let (session, factory) = makeSession(journal: journal)
        factory.configure = { host in
            host.responder = { request in
                if case .launch = request.operation { return nil }
                return FakeHost.defaultResponse(for: request)
            }
        }
        await session.connect()

        let request = Fixtures.launchRequest()
        let launch = Task { try await session.launch(request) }
        #expect(await eventually { factory.hosts[0].requests(ofKind: "launch").count == 1 })
        factory.pairs[0].closeBoth()

        await #expect(throws: RemoteClientError.disconnected) { _ = try await launch.value }
        #expect(journal.pendingKeys() == [request.operationKey])
        #expect(await eventually { session.connectionState == .disconnected })
        #expect(session.inventoryIsStale)

        await session.connect()

        #expect(factory.hosts.count == 2)
        let statusQueries = factory.hosts[1].requests(ofKind: "getOperationStatus")
        #expect(statusQueries.count == 1)
        if case .getOperationStatus(let query)? = statusQueries.first?.operation {
            #expect(query.operationKey == request.operationKey)
        }
        #expect(journal.pendingKeys().isEmpty)
        #expect(!session.inventoryIsStale)
    }

    @Test func hostRejectedLaunchClearsTheKey() async throws {
        let journal = InMemoryOperationJournal()
        let (session, factory) = makeSession(journal: journal)
        factory.configure = { host in
            host.responder = { request in
                if case .launch = request.operation {
                    return RemoteResponse(id: request.id, error: RemoteError(code: "invalid_launch", message: "No such preset"))
                }
                return FakeHost.defaultResponse(for: request)
            }
        }
        await session.connect()

        await #expect(throws: RemoteClientError.remote(RemoteError(code: "invalid_launch", message: "No such preset"))) {
            _ = try await session.launch(Fixtures.launchRequest())
        }
        #expect(journal.pendingKeys().isEmpty)
    }

    @Test func inventoryIsMarkedStaleAfterDisconnect() async throws {
        let (session, _) = makeSession()
        await session.connect()
        #expect(session.inventory != nil)

        session.disconnect()

        #expect(session.connectionState == .disconnected)
        #expect(session.inventoryIsStale)
        #expect(session.inventory == FakeHost.inventory())
    }

    @Test func inventoryChangedEventRefreshesInventory() async throws {
        let (session, factory) = makeSession()
        let revision = LockedBox<UInt64>(1)
        factory.configure = { host in
            host.responder = { request in
                if case .listInventory = request.operation {
                    return RemoteResponse(id: request.id, result: .inventory(FakeHost.inventory(revision: revision.value)))
                }
                return FakeHost.defaultResponse(for: request)
            }
        }
        await session.connect()
        #expect(session.inventory?.revision == 1)

        revision.value = 2
        await factory.hosts[0].pushEvent(.inventoryChanged(revision: 2))

        #expect(await eventually { session.inventory?.revision == 2 })
        #expect(factory.hosts[0].requests(ofKind: "listInventory").count == 2)
    }

    @Test func helloFailureMakesTheHostUnavailable() async throws {
        let (session, factory) = makeSession()
        factory.configure = { host in
            host.responder = { request in
                RemoteResponse(id: request.id, error: RemoteError(code: "unknown_device", message: "Unknown device"))
            }
        }

        await session.connect()

        #expect(session.connectionState == .unavailable(message: RemoteClientError.unauthorized("Unknown device").userMessage))
        #expect(session.inventory == nil)
    }

    @Test func worktreeBranchesReturnsTheMacsOptions() async throws {
        let (session, _) = makeSession()
        await session.connect()
        let branches = try await session.worktreeBranches(projectID: UUID(), folderID: UUID())
        #expect(branches == [WorktreeBranchOption(name: "feature", checkoutPath: nil, isCheckedOut: false)])
    }

    @Test func previewWorktreeReturnsThePath() async throws {
        let (session, _) = makeSession()
        await session.connect()

        let path = try await session.previewWorktree(projectID: UUID(), folderID: UUID(), branch: "feature-x")

        #expect(path == "/tmp/worktrees/feature-x")
    }

    @Test func makeTerminalUsesTheLiveConnection() async throws {
        let (session, factory) = makeSession()
        await session.connect()
        let adapter = FakeTerminalEngineAdapter()

        let controller = try session.makeTerminal(sessionID: UUID(), adapter: adapter)
        await controller.attach(takeControl: false)

        #expect(controller.state == .attached(generation: FakeHost.attachmentGeneration))
        #expect(factory.hosts[0].requests(ofKind: "attachTerminal").count == 1)
    }

    @Test func makeTerminalWithoutConnectionThrows() async throws {
        let (session, _) = makeSession()

        #expect(throws: RemoteClientError.disconnected) {
            _ = try session.makeTerminal(sessionID: UUID(), adapter: FakeTerminalEngineAdapter())
        }
    }

    @Test func userDefaultsJournalRoundTrips() {
        let suite = "chauffeur.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = UserDefaultsOperationJournal(defaults: defaults, key: "pending")
        let first = UUID()
        let second = UUID()

        journal.record(first)
        journal.record(second)
        journal.record(first)
        #expect(journal.pendingKeys() == [first, second])

        journal.remove(first)
        #expect(journal.pendingKeys() == [second])
        #expect(UserDefaultsOperationJournal(defaults: defaults, key: "pending").pendingKeys() == [second])
    }
}

@MainActor
struct RemoteHostSessionLivenessTests {
    private final class SilentHostFactory {
        private(set) var hosts: [FakeHost] = []
        var answersPings = true

        func makeConnection(_ savedHost: SavedHost) -> RemoteConnection {
            let pair = InMemoryTransportPair()
            let host = FakeHost(transport: pair.server)
            host.answersPings = answersPings
            host.start()
            hosts.append(host)
            return RemoteConnection(transport: pair.client, requestTimeout: .seconds(2), keepaliveInterval: nil)
        }
    }

    @Test func verifyConnectionKeepsAResponsiveHost() async throws {
        let factory = SilentHostFactory()
        let session = RemoteHostSession(host: Fixtures.savedHost(), journal: InMemoryOperationJournal(), makeConnection: { factory.makeConnection($0) })
        await session.connect()

        #expect(await session.verifyConnection(timeout: .seconds(1)))
        #expect(session.connectionState == .connected(FakeHost.hostInfo()))
    }

    @Test func verifyConnectionDropsASilentHostSoTheAppReconnects() async throws {
        let factory = SilentHostFactory()
        let session = RemoteHostSession(host: Fixtures.savedHost(), journal: InMemoryOperationJournal(), makeConnection: { factory.makeConnection($0) })
        await session.connect()
        factory.answersPings = false
        factory.hosts[0].answersPings = false

        #expect(await !session.verifyConnection(timeout: .milliseconds(200)))
        guard case .unavailable = session.connectionState else {
            Issue.record("expected unavailable, got \(session.connectionState)")
            return
        }
        #expect(session.inventoryIsStale)

        factory.answersPings = true
        await session.connect()
        #expect(session.connectionState == .connected(FakeHost.hostInfo()))
        #expect(factory.hosts.count == 2)
    }
}
