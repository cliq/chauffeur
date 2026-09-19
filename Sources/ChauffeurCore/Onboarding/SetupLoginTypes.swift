import Foundation

public struct SetupLoginHandle: Codable, Equatable, Sendable {
    public var operationID: UUID
    public var generation: UInt64
    public var phase: SetupAuthPhase

    public init(operationID: UUID, generation: UInt64, phase: SetupAuthPhase) {
        self.operationID = operationID
        self.generation = generation
        self.phase = phase
    }
}

/// One bounded slice of ephemeral login-terminal output. Codable represents
/// `bytes` as base64 on the IPC boundary.
public struct SetupLoginOutput: Codable, Equatable, Sendable {
    public var bytes: Data
    public var nextCursor: UInt64
    public var oldestCursor: UInt64
    public var running: Bool
    public var exitStatus: Int32?
    public var generation: UInt64

    public init(bytes: Data, nextCursor: UInt64, oldestCursor: UInt64, running: Bool, exitStatus: Int32?, generation: UInt64) {
        self.bytes = bytes
        self.nextCursor = nextCursor
        self.oldestCursor = oldestCursor
        self.running = running
        self.exitStatus = exitStatus
        self.generation = generation
    }
}
