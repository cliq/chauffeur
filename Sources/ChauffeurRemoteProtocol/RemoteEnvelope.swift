import Foundation

public enum RemoteProtocol {
    public static let version = 1
    public static let capabilities = ["terminal.binary.v1", "launch.worktree.v1", "inventory.v1", "progress.v1", openSessionKinds]
    /// A client with this capability decodes any session kind (an unknown one as `agent`). Builds without it fail to
    /// decode a whole inventory that names a kind they don't know, so the Mac sends them `shell` instead.
    public static let openSessionKinds = "sessionKinds.open.v1"
    /// The kinds every client decodes, including those without `openSessionKinds`.
    public static let legacySessionKinds: Set<RemoteSessionKind> = [.codex, .claude, .shell]
}

public struct RemoteError: Codable, Equatable, Sendable, Error {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct RemoteRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var id: UUID
    public var operation: RemoteOperation

    public init(id: UUID = UUID(), operation: RemoteOperation) {
        self.protocolVersion = RemoteProtocol.version
        self.id = id
        self.operation = operation
    }
}

public struct RemoteResponse: Codable, Equatable, Sendable {
    public var id: UUID
    public var result: RemoteResult?
    public var error: RemoteError?

    public init(id: UUID, result: RemoteResult) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: UUID, error: RemoteError) {
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// Out-of-band notifications pushed from the Mac runtime to attached clients.
public enum RemoteEvent: Equatable, Sendable, Codable {
    case inventoryChanged(revision: UInt64)
    case sessionChanged(SessionSummary)
    case attachmentEnded(generation: UInt64, reason: AttachmentEndReason, message: String?)
    case operationUpdated(OperationStatus)
    case accessRevoked

    private struct InventoryChangedPayload: Codable {
        var revision: UInt64
    }

    private struct AttachmentEndedPayload: Codable {
        var generation: UInt64
        var reason: AttachmentEndReason
        var message: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RemoteEnvelopeCodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "inventoryChanged":
            let payload = try container.decode(InventoryChangedPayload.self, forKey: .payload)
            self = .inventoryChanged(revision: payload.revision)
        case "sessionChanged":
            self = .sessionChanged(try container.decode(SessionSummary.self, forKey: .payload))
        case "attachmentEnded":
            let payload = try container.decode(AttachmentEndedPayload.self, forKey: .payload)
            self = .attachmentEnded(generation: payload.generation, reason: payload.reason, message: payload.message)
        case "operationUpdated":
            self = .operationUpdated(try container.decode(OperationStatus.self, forKey: .payload))
        case "accessRevoked":
            self = .accessRevoked
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown RemoteEvent kind: \(kind)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RemoteEnvelopeCodingKeys.self)
        switch self {
        case .inventoryChanged(let revision):
            try container.encode("inventoryChanged", forKey: .kind)
            try container.encode(InventoryChangedPayload(revision: revision), forKey: .payload)
        case .sessionChanged(let summary):
            try container.encode("sessionChanged", forKey: .kind)
            try container.encode(summary, forKey: .payload)
        case .attachmentEnded(let generation, let reason, let message):
            try container.encode("attachmentEnded", forKey: .kind)
            try container.encode(AttachmentEndedPayload(generation: generation, reason: reason, message: message), forKey: .payload)
        case .operationUpdated(let status):
            try container.encode("operationUpdated", forKey: .kind)
            try container.encode(status, forKey: .payload)
        case .accessRevoked:
            try container.encode("accessRevoked", forKey: .kind)
        }
    }
}

/// Shared `kind` / `payload` discriminator coding keys for the hand-written
/// `Codable` conformances of `RemoteOperation`, `RemoteResult`, and `RemoteEvent`.
enum RemoteEnvelopeCodingKeys: String, CodingKey {
    case kind
    case payload
}
