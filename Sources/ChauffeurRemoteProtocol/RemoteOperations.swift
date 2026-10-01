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

public struct ListWorktreeBranchesRequest: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var folderID: UUID
    public init(projectID: UUID, folderID: UUID) {
        self.projectID = projectID; self.folderID = folderID
    }
}

public struct WorktreeBranchOption: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var checkoutPath: String?
    public var isCheckedOut: Bool
    public var id: String { name }
    public init(name: String, checkoutPath: String?, isCheckedOut: Bool) {
        self.name = name; self.checkoutPath = checkoutPath; self.isCheckedOut = isCheckedOut
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

/// Asks the Mac whether text pasted into a launch form names an issue-tracker ticket.
public struct ResolveTicketRequest: Codable, Equatable, Sendable {
    public var projectID: UUID
    public var folderID: UUID
    public var text: String

    public init(projectID: UUID, folderID: UUID, text: String) {
        self.projectID = projectID; self.folderID = folderID; self.text = text
    }
}

/// A ticket with the repository's branch template already applied. Forms rewrite their title, and an
/// empty task, only when `url` is set; a bare key only changes the suggested branch.
public struct TicketSuggestion: Codable, Equatable, Sendable {
    public var key: String?
    public var number: String
    public var url: String?
    public var branch: String
    public var title: String
    public var task: String?

    public init(key: String?, number: String, url: String?, branch: String, title: String, task: String?) {
        self.key = key; self.number = number; self.url = url; self.branch = branch; self.title = title; self.task = task
    }
}

/// `ticket` is nil when the text is not a ticket.
public struct TicketSuggestionResult: Codable, Equatable, Sendable {
    public var ticket: TicketSuggestion?

    public init(ticket: TicketSuggestion?) { self.ticket = ticket }
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

/// One piece of a file the phone sends to the Mac. Chunks arrive in order; `offset` is where
/// `data` starts, and the upload finishes when `offset + data.count == totalBytes`. Resending a
/// chunk the Mac already has is accepted, so a retry after a lost response is safe.
public struct UploadFileChunkRequest: Codable, Equatable, Sendable {
    public static let chunkBytes = 1024 * 1024
    public static let maxTotalBytes: Int64 = 100 * 1024 * 1024
    public var uploadID: UUID
    public var filename: String
    public var totalBytes: Int64
    public var offset: Int64
    public var data: Data

    public init(uploadID: UUID, filename: String, totalBytes: Int64, offset: Int64, data: Data) {
        self.uploadID = uploadID; self.filename = filename; self.totalBytes = totalBytes; self.offset = offset; self.data = data
    }
}

/// How much of an upload the Mac holds; `path` is set once the whole file arrived.
public struct UploadedFileStatus: Codable, Equatable, Sendable {
    public var uploadID: UUID
    public var receivedBytes: Int64
    public var path: String?

    public init(uploadID: UUID, receivedBytes: Int64, path: String? = nil) {
        self.uploadID = uploadID; self.receivedBytes = receivedBytes; self.path = path
    }
}

// MARK: - RemoteOperation

public enum RemoteOperation: Equatable, Sendable, Codable {
    case hello(HelloRequest)
    case pair(PairRequest)
    case listInventory(ListInventoryRequest)
    case getSessionProgress(SessionProgressRequest)
    case listWorktreeBranches(ListWorktreeBranchesRequest)
    case previewWorktreeDestination(PreviewWorktreeRequest)
    case launch(LaunchOperationRequest)
    case getOperationStatus(OperationStatusRequest)
    case attachTerminal(AttachTerminalRequest)
    case terminalResize(TerminalResizeRequest)
    case detachTerminal(DetachTerminalRequest)
    case getKeepAwake
    case setKeepAwakeSettings(KeepAwakeSettings)
    case setKeepAwakeTimer(KeepAwakeTimerRequest)
    case uploadFileChunk(UploadFileChunkRequest)
    case resolveTicket(ResolveTicketRequest)

    public var kind: String {
        switch self {
        case .hello: return "hello"
        case .pair: return "pair"
        case .listInventory: return "listInventory"
        case .getSessionProgress: return "getSessionProgress"
        case .listWorktreeBranches: return "listWorktreeBranches"
        case .previewWorktreeDestination: return "previewWorktreeDestination"
        case .launch: return "launch"
        case .getOperationStatus: return "getOperationStatus"
        case .attachTerminal: return "attachTerminal"
        case .terminalResize: return "terminalResize"
        case .detachTerminal: return "detachTerminal"
        case .getKeepAwake: return "getKeepAwake"
        case .setKeepAwakeSettings: return "setKeepAwakeSettings"
        case .setKeepAwakeTimer: return "setKeepAwakeTimer"
        case .uploadFileChunk: return "uploadFileChunk"
        case .resolveTicket: return "resolveTicket"
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
        case "listWorktreeBranches":
            self = .listWorktreeBranches(try container.decode(ListWorktreeBranchesRequest.self, forKey: .payload))
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
        case "getKeepAwake":
            self = .getKeepAwake
        case "setKeepAwakeSettings":
            self = .setKeepAwakeSettings(try container.decode(KeepAwakeSettings.self, forKey: .payload))
        case "setKeepAwakeTimer":
            self = .setKeepAwakeTimer(try container.decode(KeepAwakeTimerRequest.self, forKey: .payload))
        case "uploadFileChunk":
            self = .uploadFileChunk(try container.decode(UploadFileChunkRequest.self, forKey: .payload))
        case "resolveTicket":
            self = .resolveTicket(try container.decode(ResolveTicketRequest.self, forKey: .payload))
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
        case .listWorktreeBranches(let payload):
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
        case .getKeepAwake:
            break
        case .setKeepAwakeSettings(let payload):
            try container.encode(payload, forKey: .payload)
        case .setKeepAwakeTimer(let payload):
            try container.encode(payload, forKey: .payload)
        case .uploadFileChunk(let payload):
            try container.encode(payload, forKey: .payload)
        case .resolveTicket(let payload):
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
    case worktreeBranches([WorktreeBranchOption])
    case worktreeDestination(WorktreeDestinationPreview)
    case operation(OperationStatus)
    case attachment(AttachmentInfo)
    case keepAwake(KeepAwakeStatus)
    case uploadedFile(UploadedFileStatus)
    case ticketSuggestion(TicketSuggestionResult)
    case ack

    public var kind: String {
        switch self {
        case .hostInfo: return "hostInfo"
        case .pairing: return "pairing"
        case .inventory: return "inventory"
        case .sessionProgress: return "sessionProgress"
        case .worktreeBranches: return "worktreeBranches"
        case .worktreeDestination: return "worktreeDestination"
        case .operation: return "operation"
        case .attachment: return "attachment"
        case .keepAwake: return "keepAwake"
        case .uploadedFile: return "uploadedFile"
        case .ticketSuggestion: return "ticketSuggestion"
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
        case "worktreeBranches":
            self = .worktreeBranches(try container.decode([WorktreeBranchOption].self, forKey: .payload))
        case "worktreeDestination":
            self = .worktreeDestination(try container.decode(WorktreeDestinationPreview.self, forKey: .payload))
        case "operation":
            self = .operation(try container.decode(OperationStatus.self, forKey: .payload))
        case "attachment":
            self = .attachment(try container.decode(AttachmentInfo.self, forKey: .payload))
        case "keepAwake":
            self = .keepAwake(try container.decode(KeepAwakeStatus.self, forKey: .payload))
        case "uploadedFile":
            self = .uploadedFile(try container.decode(UploadedFileStatus.self, forKey: .payload))
        case "ticketSuggestion":
            self = .ticketSuggestion(try container.decode(TicketSuggestionResult.self, forKey: .payload))
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
        case .worktreeBranches(let payload):
            try container.encode(payload, forKey: .payload)
        case .worktreeDestination(let payload):
            try container.encode(payload, forKey: .payload)
        case .operation(let payload):
            try container.encode(payload, forKey: .payload)
        case .attachment(let payload):
            try container.encode(payload, forKey: .payload)
        case .keepAwake(let payload):
            try container.encode(payload, forKey: .payload)
        case .uploadedFile(let payload):
            try container.encode(payload, forKey: .payload)
        case .ticketSuggestion(let payload):
            try container.encode(payload, forKey: .payload)
        case .ack:
            break
        }
    }
}
