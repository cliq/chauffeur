import Foundation
import ChauffeurRemoteProtocol

/// Turns a pairing code shown on the Mac into a `SavedHost`.
public enum PairingClient {
    /// Connects to `host:pairingPort` with the PSK derived from the code, sends `pair`, and
    /// returns the saved host: the host string as typed, the port from the pairing result.
    public static func pair(
        host: String,
        pairingPort: Int,
        code: String,
        deviceName: String,
        makeTransport: @Sendable (RemoteEndpoint, Data) -> any RemoteTransport = { NetworkTransport(endpoint: $0, presharedKey: $1) }
    ) async throws -> SavedHost {
        guard let normalized = PairingKeyDerivation.normalize(code) else {
            throw RemoteClientError.invalidResponse("Pairing code must be \(PairingKeyDerivation.codeLength) characters")
        }
        let presharedKey = PairingKeyDerivation.derive(normalizedCode: normalized)
        let transport = makeTransport(RemoteEndpoint(host: host, port: pairingPort), presharedKey)
        let connection = RemoteConnection(transport: transport)
        defer {
            Task { await connection.close() }
        }

        try await connection.open()
        let result = try await connection.request(.pair(PairRequest(deviceName: deviceName, protocolVersion: RemoteProtocol.version)))
        guard case .pairing(let pairing) = result else {
            throw RemoteClientError.invalidResponse("pair returned \(result.kind)")
        }
        return SavedHost(
            hostID: pairing.hostID,
            name: pairing.hostName,
            host: host,
            port: pairing.mainPort,
            remoteAccessKey: pairing.remoteAccessKey,
            deviceID: pairing.deviceID,
            deviceToken: pairing.deviceToken,
            pairedAt: Date()
        )
    }
}
