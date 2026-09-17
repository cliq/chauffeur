import Foundation

/// Desktop-facing view of the runtime's remote access state, returned by the `remoteAccessStatus`,
/// `setRemoteAccess`, `beginPairing`, `cancelPairing`, `revokeRemoteDevice` and `resetRemoteAccess`
/// IPC methods and included in the subscribe snapshot as `remoteAccess`.
public struct RemoteAccessStatus: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var pairedAt: Date
        public var lastSeenAt: Date?
        public var connected: Bool

        public init(id: UUID, name: String, pairedAt: Date, lastSeenAt: Date? = nil, connected: Bool = false) {
            self.id = id
            self.name = name
            self.pairedAt = pairedAt
            self.lastSeenAt = lastSeenAt
            self.connected = connected
        }
    }

    public struct Pairing: Codable, Equatable, Sendable {
        /// Display form, `XXXX-XXXX-XX`.
        public var code: String
        public var expiresAt: Date
        public var port: Int

        public init(code: String, expiresAt: Date, port: Int) {
            self.code = code
            self.expiresAt = expiresAt
            self.port = port
        }
    }

    public var enabled: Bool
    public var listening: Bool
    public var port: Int
    public var hostName: String
    /// LAN addresses the phone can type, e.g. `192.168.1.20`; empty when none is known.
    public var addresses: [String]
    /// Short hex fingerprint of the current access key; safe to show, never the key itself.
    public var keyFingerprint: String
    public var error: String?
    public var devices: [Device]
    public var pairing: Pairing?

    public init(enabled: Bool = false, listening: Bool = false, port: Int, hostName: String, addresses: [String] = [],
                keyFingerprint: String, error: String? = nil, devices: [Device] = [], pairing: Pairing? = nil) {
        self.enabled = enabled
        self.listening = listening
        self.port = port
        self.hostName = hostName
        self.addresses = addresses
        self.keyFingerprint = keyFingerprint
        self.error = error
        self.devices = devices
        self.pairing = pairing
    }
}
