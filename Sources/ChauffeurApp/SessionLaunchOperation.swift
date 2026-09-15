import Foundation
import Combine
import ChauffeurCore

@MainActor final class SessionLaunchOperation: ObservableObject {
    @Published private(set) var progress: String?
    @Published private(set) var failure: String?
    @Published private(set) var createdWorktree: Worktree?
    private var request: LaunchRequest?
    private var creation: WorktreeCreationRequest?
    var isBusy: Bool { progress != nil }
    var canRetry: Bool { request != nil }

    func retry(model: AppModel) async -> Session? {
        guard let request else { return nil }
        return await launch(request, creating: creation, retry: true, model: model)
    }

    func launch(_ proposed: LaunchRequest, creating proposedCreation: WorktreeCreationRequest?, retry: Bool, model: AppModel) async -> Session? {
        guard !isBusy else { return nil }
        if !retry {
            var newCreation = proposedCreation
            // A lost creation response is retried with the same key even when
            // the user starts a fresh agent attempt with edited session fields.
            if let pending = creation, let current = newCreation,
               pending.projectID == current.projectID, pending.folderID == current.folderID,
               pending.branch == current.branch, pending.baseRef == current.baseRef {
                newCreation?.retryKey = pending.retryKey
            }
            request = proposed; creation = newCreation
        }
        guard var request else { return nil }
        failure = nil; progress = creation == nil ? "Launching…" : "Creating worktree…"
        defer { progress = nil }
        do {
            if let creation {
                let worktree = try await model.call("createWorktree", .from(creation)).decode(Stored<Worktree>.self).value
                guard worktree.registered, worktree.availability == .available else { throw ChauffeurError("worktree_unavailable", "This worktree is no longer registered or available. Choose another checkout") }
                createdWorktree = worktree
                request.worktreeID = worktree.id; request.allowSharedCheckout = false
                self.request = request; self.creation = nil
            }
            progress = "Launching…"
            let session = try await model.call("launch", .from(request)).decode(Session.self)
            try await model.refresh()
            return session
        } catch {
            failure = error.localizedDescription
            try? await model.refresh()
            return nil
        }
    }
}
