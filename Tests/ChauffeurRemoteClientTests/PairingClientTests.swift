import Foundation
import Testing
import ChauffeurRemoteProtocol
@testable import ChauffeurRemoteClient

@MainActor
struct PairingClientTests {
    @Test func invalidCodeIsRejectedWithoutConnecting() async {
        let transportRequests = LockedBox(0)

        await #expect(throws: RemoteClientError.invalidResponse("Pairing code must be 10 characters")) {
            _ = try await PairingClient.pair(
                host: "192.168.1.10",
                pairingPort: 51848,
                code: "ABC",
                deviceName: "Phone",
                makeTransport: { _, _ in
                    transportRequests.value += 1
                    return InMemoryTransportPair().client
                }
            )
        }
        #expect(transportRequests.value == 0)
    }

    @Test func successfulPairReturnsSavedHostFromTheResult() async throws {
        let pair = InMemoryTransportPair()
        let host = FakeHost(transport: pair.server)
        host.start()
        let seenEndpoint = LockedBox<RemoteEndpoint?>(nil)
        let seenKey = LockedBox<Data?>(nil)

        let saved = try await PairingClient.pair(
            host: "192.168.1.10",
            pairingPort: 51848,
            code: "abcd-efgh-jk",
            deviceName: "Leo's iPhone",
            makeTransport: { endpoint, key in
                seenEndpoint.value = endpoint
                seenKey.value = key
                return pair.client
            }
        )

        #expect(seenEndpoint.value == RemoteEndpoint(host: "192.168.1.10", port: 51848))
        #expect(seenKey.value == PairingKeyDerivation.derive(normalizedCode: "ABCDEFGHJK"))
        #expect(saved.host == "192.168.1.10")
        #expect(saved.port == FakeHost.mainPort)
        #expect(saved.hostID == FakeHost.hostID)
        #expect(saved.name == "fake-mac")
        #expect(saved.deviceToken == "token-123")
        #expect(saved.remoteAccessKey == Data(repeating: 0xAB, count: 32))

        let pairs = host.requests(ofKind: "pair")
        #expect(pairs.count == 1)
        #expect(host.requests(ofKind: "hello").isEmpty)
        if case .pair(let request)? = pairs.first?.operation {
            #expect(request == PairRequest(deviceName: "Leo's iPhone", protocolVersion: RemoteProtocol.version))
        }
    }

    @Test func hostErrorDuringPairingIsSurfaced() async {
        let pair = InMemoryTransportPair()
        let host = FakeHost(transport: pair.server)
        host.responder = { request in
            RemoteResponse(id: request.id, error: RemoteError(code: "pairing_closed", message: "Pairing window closed"))
        }
        host.start()

        await #expect(throws: RemoteClientError.remote(RemoteError(code: "pairing_closed", message: "Pairing window closed"))) {
            _ = try await PairingClient.pair(host: "h", pairingPort: 1, code: "ABCDEFGHJK", deviceName: "p", makeTransport: { _, _ in pair.client })
        }
    }
}
