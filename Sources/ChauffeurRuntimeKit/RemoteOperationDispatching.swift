import Foundation
import ChauffeurRemoteProtocol

/// Handles the remote operations that are not about a single terminal
/// attachment (inventory, launches, worktree previews, operation status).
/// The remote listener authenticates the device and forwards the operation.
public protocol RemoteOperationDispatching: Sendable {
    func handle(_ operation: RemoteOperation, deviceID: UUID) async -> Result<RemoteResult, RemoteError>
    /// Monotonic revision of the inventory a client can list; the listener
    /// pushes `inventoryChanged` to every authenticated client when it moves.
    func inventoryRevision() async -> UInt64
}

/// Default dispatcher: every forwarded operation is unsupported and the
/// inventory never changes.
public struct UnavailableDispatcher: RemoteOperationDispatching {
    public init() {}
    public func handle(_ operation: RemoteOperation, deviceID: UUID) async -> Result<RemoteResult, RemoteError> {
        .failure(RemoteError(code: "unsupported_operation", message: "This Mac does not support the \(operation.kind) operation yet"))
    }
    public func inventoryRevision() async -> UInt64 { 0 }
}
