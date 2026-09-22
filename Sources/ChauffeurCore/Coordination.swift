import Foundation

public struct GroupScope: Codable, Equatable, Sendable {
    public let projectID: UUID
    public let groupID: UUID
    public init(projectID: UUID, groupID: UUID) { self.projectID = projectID; self.groupID = groupID }
}
public struct Caller: Codable, Sendable {
    public var sessionID: UUID
    public var scope: GroupScope
    public init(sessionID: UUID, scope: GroupScope) { self.sessionID = sessionID; self.scope = scope }
}
public enum DeliveryState: String, Codable, Sendable { case queued, received, acknowledged, failed, cancelled }
public struct Message: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var scope: GroupScope
    public var senderID: UUID
    public var recipientID: UUID
    public var body: String
    public var references: [String]
    public var state: DeliveryState = .queued
    public var replyToID: UUID?
    public var turnID: UUID?
    public var delegationID: UUID?
    public var createdAt = Date()
    public var receivedAt: Date?
    public var acknowledgedAt: Date?
    public init(scope: GroupScope, senderID: UUID, recipientID: UUID, body: String, references: [String] = [], replyToID: UUID? = nil, delegationID: UUID? = nil) {
        self.scope = scope; self.senderID = senderID; self.recipientID = recipientID; self.body = body; self.references = references; self.replyToID = replyToID; self.delegationID = delegationID
    }
}
public enum DelegationState: String, Codable, Sendable { case reserved, launching, running, resultReported, exited, failed, cancelled, interrupted }
public struct Delegation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var scope: GroupScope
    public var parentID: UUID
    public var childID: UUID
    public var task: String
    public var presetID: UUID
    public var folderID: UUID
    public var shareCheckout: Bool
    public var worktreeID: UUID?
    public var state: DelegationState = .reserved
    public var result: String?
    public var turnID: UUID?
    public var controllerID: UUID?
    public var model: String?
    public var reasoningEffort: String?
    public var predecessorID: UUID?
    public var closureOutcome: String?
    public var closureReason: String?
    public var currentTurnID: UUID { turnID ?? id }
    public var controllingParentID: UUID { controllerID ?? parentID }
    public var error: String?
    public var createdAt = Date()
    public init(scope: GroupScope, parentID: UUID, childID: UUID = UUID(), task: String, presetID: UUID, folderID: UUID, shareCheckout: Bool) {
        self.scope = scope; self.parentID = parentID; self.childID = childID; self.task = task; self.presetID = presetID; self.folderID = folderID; self.shareCheckout = shareCheckout
    }
}

/// A durable receipt, not a promise that terminal input was consumed.
public struct CoordinationOperation: Codable, Equatable, Sendable {
    public var id = UUID()
    public var callerID: UUID
    public var delegationID: UUID
    public var kind: String
    public var state = "reserved"
    public var turnID: UUID?
    public var error: String?
    public var errorCode: String?
    public var historyWarning: String?
    public var createdAt = Date()
    public init(callerID: UUID, delegationID: UUID, kind: String) {
        self.callerID = callerID; self.delegationID = delegationID; self.kind = kind
    }
}
