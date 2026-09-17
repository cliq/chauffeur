import Foundation

extension RemoteOperationHandlers: RemoteOperationDispatching {
    /// Rebuilds the inventory so the revision moves when the store or sessions changed,
    /// mirroring the 1 s digest poll the local `subscribe` stream already performs.
    public func inventoryRevision() async -> UInt64 {
        (try? await inventory())?.revision ?? currentRevision()
    }
}
