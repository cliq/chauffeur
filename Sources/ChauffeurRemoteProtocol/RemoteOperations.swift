import Foundation

// MARK: - Request payloads

public struct HelloRequest: Codable, Equatable, Sendable {
    public var deviceID: UUID
    public var deviceToken: String
    public var clientName: String
    public var clientVersion: String
    public var protocolVersion: Int
    public var capabilities: [String]

    public init(
        deviceID: UUID,
        deviceToken: String,
        clientName: String,
        clientVersion: String,
        protocolVersion: Int,
        capabilities: [String] = []
    ) {
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

public struct PairRequest: Codable, Equatable, Sendable {
    public var deviceName: String
    public var protocolVersion: Int

    public init(deviceName: String, protocolVersion: Int) {
        self.deviceName = deviceName
        self.protocolVersion = protocolVersion
    }
}

public struct ListInventoryRequest: Codable, Equatable, Sendable {
    public var sinceRevision: UInt64?

    public init(sinceRevision: UInt64? = nil) {
        self.sinceRevision = sinceRevision
    }
}

public struct PreviewWorktreeRequest: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var folderID: UUID
    public var branch: String

    public init(projectID: UUID, folderID: UUID, branch: String) {
        self.projectID = projectID
        self.folderID = folderID
        self.branch = branch
    }
}

public struct AttachTerminalRequest: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var takeControl: Bool
    public var cols: Int
    public var rows: Int

    public init(sessionID: UUID, takeControl: Bool = false, cols: Int, rows: Int) {
        self.sessionID = sessionID
        self.takeControl = takeControl
        self.cols = cols
        self.rows = rows
    }
}

public struct TerminalResizeRequest: Codable, Equatable, Sendable {
    public var generation: UInt64
    public var cols: Int
    public var rows: Int

    public init(generation: UInt64, cols: Int, rows: Int) {
        self.generation = generation
        self.cols = cols
        self.rows = rows
    }
}

public struct DetachTerminalRequest: Codable, Equatable, Sendable {
    public var generation: UInt64

    public init(generation: UInt64) {
        self.generation = generation
    }
}

public struct OperationStatusRequest: Codable, Equatable, Sendable {
    public var operationKey: UUID

    public init(operationKey: UUID) {
        self.operationKey = operationKey
    }
}

// MARK: - RemoteOperation

public enum RemoteOperation: Equatable, Sendable, Codable {
    case hello(HelloRequest)
    case pair(PairRequest)
    case listInventory(ListInventoryRequest)
    case getSessionProgress(SessionProgressRequest)
    case previewWorktreeDestination(PreviewWorktreeRequest)
    case launch(LaunchOperationRequest)
    case getOperationStatus(OperationStatusRequest)
    case attachTerminal(AttachTerminalRequest)
    case terminalResize(TerminalResizeRequest)
    case detachTerminal(DetachTerminalRequest)

    public var kind: String {
        switch self {
        case .hello: return "hello"
        case .pair: return "pair"
        case .listInventory: return "listInventory"
        case .getSessionProgress: return "getSessionProgress"
        case .previewWorktreeDestination: return "previewWorktreeDestination"
        case .launch: return "launch"
        case .getOperationStatus: return "getOperationStatus"
        case .attachTerminal: return "attachTerminal"
        case .terminalResize: return "terminalResize"
        case .detachTerminal: return "detachTerminal"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RemoteEnvelopeCodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "hello":
            self = .hello(try container.decode(HelloRequest.self, forKey: .payload))
        case "pair":
            self = .pair(try container.decode(PairRequest.self, forKey: .payload))
        case "getSessionProgress":
            self = .getSessionProgress(try container.decode(SessionProgressRequest.self, forKey: .payload))
        case "listInventory":
            self = .listInventory(try container.decode(ListInventoryRequest.self, forKey: .payload))
        case "previewWorktreeDestination":
            self = .previewWorktreeDestination(try container.decode(PreviewWorktreeRequest.self, forKey: .payload))
        case "launch":
            self = .launch(try container.decode(LaunchOperationRequest.self, forKey: .payload))
        case "getOperationStatus":
            self = .getOperationStatus(try container.decode(OperationStatusRequest.self, forKey: .payload))
        case "attachTerminal":
            self = .attachTerminal(try container.decode(AttachTerminalRequest.self, forKey: .payload))
        case "terminalResize":
            self = .terminalResize(try container.decode(TerminalResizeRequest.self, forKey: .payload))
        case "detachTerminal":
            self = .detachTerminal(try container.decode(DetachTerminalRequest.self, forKey: .payload))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown RemoteOperation kind: \(kind)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RemoteEnvelopeCodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .hello(let payload):
            try container.encode(payload, forKey: .payload)
        case .pair(let payload):
            try container.encode(payload, forKey: .payload)
        case .getSessionProgress(let payload):
            try container.encode(payload, forKey: .payload)
        case .listInventory(let payload):
            try container.encode(payload, forKey: .payload)
        case .previewWorktreeDestination(let payload):
            try container.encode(payload, forKey: .payload)
        case .launch(let payload):
            try container.encode(payload, forKey: .payload)
        case .getOperationStatus(let payload):
            try container.encode(payload, forKey: .payload)
        case .attachTerminal(let payload):
            try container.encode(payload, forKey: .payload)
        case .terminalResize(let payload):
            try container.encode(payload, forKey: .payload)
        case .detachTerminal(let payload):
            try container.encode(payload, forKey: .payload)
        }
    }
}

// MARK: - RemoteResult

public enum RemoteResult: Equatable, Sendable, Codable {
    case hostInfo(HostInfo)
    case pairing(PairingResult)
    case inventory(InventorySnapshot)
    case sessionProgress(SessionProgressPanel)
    case worktreeDestination(WorktreeDestinationPreview)
    case operation(OperationStatus)
    case attachment(AttachmentInfo)
    case ack

    public var kind: String {
        switch self {
        case .hostInfo: return "hostInfo"
        case .pairing: return "pairing"
        case .inventory: return "inventory"
        case .sessionProgress: return "sessionProgress"
        case .worktreeDestination: return "worktreeDestination"
        case .operation: return "operation"
        case .attachment: return "attachment"
        case .ack: return "ack"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RemoteEnvelopeCodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "hostInfo":
            self = .hostInfo(try container.decode(HostInfo.self, forKey: .payload))
        case "pairing":
            self = .pairing(try container.decode(PairingResult.self, forKey: .payload))
        case "sessionProgress":
            self = .sessionProgress(try container.decode(SessionProgressPanel.self, forKey: .payload))
        case "inventory":
            self = .inventory(try container.decode(InventorySnapshot.self, forKey: .payload))
        case "worktreeDestination":
            self = .worktreeDestination(try container.decode(WorktreeDestinationPreview.self, forKey: .payload))
        case "operation":
            self = .operation(try container.decode(OperationStatus.self, forKey: .payload))
        case "attachment":
            self = .attachment(try container.decode(AttachmentInfo.self, forKey: .payload))
        case "ack":
            self = .ack
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown RemoteResult kind: \(kind)"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RemoteEnvelopeCodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .hostInfo(let payload):
            try container.encode(payload, forKey: .payload)
        case .pairing(let payload):
            try container.encode(payload, forKey: .payload)
        case .sessionProgress(let payload):
            try container.encode(payload, forKey: .payload)
        case .inventory(let payload):
            try container.encode(payload, forKey: .payload)
        case .worktreeDestination(let payload):
            try container.encode(payload, forKey: .payload)
        case .operation(let payload):
            try container.encode(payload, forKey: .payload)
        case .attachment(let payload):
            try container.encode(payload, forKey: .payload)
        case .ack:
            break
        }
    }
}
