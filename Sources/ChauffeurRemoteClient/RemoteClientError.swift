import Foundation
import ChauffeurRemoteProtocol

/// Every failure the remote client surfaces to the app. Each case carries enough detail for
/// diagnostics and maps to one short `userMessage` suitable for a status line or alert.
public enum RemoteClientError: Error, Equatable, Sendable {
    case protocolMismatch(hostVersion: Int, clientVersion: Int)
    /// Wrong pre-shared key or any other TLS handshake failure.
    case authenticationFailed
    /// The host rejected `hello` (unknown or revoked device).
    case unauthorized(String)
    /// An operation error returned by the host.
    case remote(RemoteError)
    case network(String)
    case timeout
    case disconnected
    case framing(String)
    case invalidResponse(String)

    public var userMessage: String {
        switch self {
        case .protocolMismatch:
            return "This Mac runs a different Chauffeur version. Update both apps."
        case .authenticationFailed:
            return "This Mac did not accept the pairing key. Pair again."
        case .unauthorized:
            return "This device is no longer authorized on the Mac. Pair again."
        case .remote(let error):
            return error.message
        case .network:
            return "Could not reach the Mac. Check that it is awake and on the same network."
        case .timeout:
            return "The Mac did not respond in time."
        case .disconnected:
            return "Disconnected from the Mac."
        case .framing:
            return "The connection received malformed data and was closed."
        case .invalidResponse(let message):
            return message
        }
    }
}
