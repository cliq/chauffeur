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
