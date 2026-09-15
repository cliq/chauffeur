import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct CheckoutClaimsTests {
    @Test func bothInterleavingsProtectPrimaryAdditionalAndMovedCheckouts() throws {
        var claims = CheckoutClaims()
        let sessionID = UUID(), worktreeID = UUID(), removalID = UUID()
        try claims.beginLaunch(sessionID, paths: ["/tmp/repo", "/tmp/other/subdirectory"], worktreeID: worktreeID)
        // Preflight has not created a Session record yet.
        #expect(throws: ChauffeurError.self) { try claims.beginRemoval(removalID, path: "/tmp/repo", worktreeIDs: [], sessions: []) }
        #expect(throws: ChauffeurError.self) { try claims.beginRemoval(removalID, path: "/tmp/other", worktreeIDs: [], sessions: []) }
        #expect(throws: ChauffeurError.self) { try claims.beginRemoval(removalID, path: "/tmp/moved", worktreeIDs: [worktreeID], sessions: []) }
        claims.endLaunch(sessionID)
        try claims.beginRemoval(removalID, path: "/tmp/repo", worktreeIDs: [worktreeID], sessions: [])
        #expect(throws: ChauffeurError.self) { try claims.beginLaunch(sessionID, paths: ["/tmp/repo/src"], worktreeID: nil) }
        #expect(throws: ChauffeurError.self) { try claims.beginLaunch(sessionID, paths: ["/tmp/unrelated", "/tmp/repo"], worktreeID: nil) }
        #expect(throws: ChauffeurError.self) { try claims.beginLaunch(sessionID, paths: ["/tmp/old-path"], worktreeID: worktreeID) }
        // A path prefix without a component boundary is a different checkout.
        try claims.beginLaunch(UUID(), paths: ["/tmp/repo-other"], worktreeID: nil)
        claims.endRemoval(removalID)
        try claims.beginLaunch(sessionID, paths: ["/tmp/repo"], worktreeID: worktreeID)
    }
    @Test func liveReferencesBlockRemovalAcrossMovesAndAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-claims-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.appendingPathComponent("alias"), checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: checkout)
        var claims = CheckoutClaims()
        try claims.beginRemoval(UUID(), path: checkout.path, worktreeIDs: [], sessions: [])
        #expect(throws: ChauffeurError.self) { try claims.beginLaunch(UUID(), paths: [alias.path], worktreeID: nil) }
        let set = PresetSet(name: "Fixture"), treeID = UUID()
        let preset = AgentPreset(setID: set.id, name: "Fixture", kind: .codex, executable: "/bin/cat", configurationDirectory: root.path)
        let snapshot = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat", executableVersion: "1.0.0", workingDirectory: "/tmp/old-location", additionalPaths: [])
        var session = Session(projectID: UUID(), groupID: UUID(), title: "Live", launch: snapshot, folderID: UUID())
        session.worktreeID = treeID; session.state = .activityUnknown
        #expect(throws: ChauffeurError.self) { try claims.beginRemoval(UUID(), path: "/tmp/moved-location", worktreeIDs: [treeID], sessions: [session]) }
        session.state = .exited
        try claims.beginRemoval(UUID(), path: "/tmp/moved-location", worktreeIDs: [treeID], sessions: [session])
    }
    @Test func gitIdentityProtectsFolderSessionsAfterMovesAndConcurrentSharingIsExplicit() throws {
        var claims = CheckoutClaims()
        let sessionID = UUID(), identity = UUID(), removalID = UUID()
        try claims.beginLaunch(sessionID, paths: ["/tmp/original"], worktreeID: nil, allowSharedCheckout: false)
        #expect(throws: ChauffeurError.self) { try claims.beginLaunch(UUID(), paths: ["/tmp/original"], worktreeID: nil, allowSharedCheckout: false) }
        try claims.setGitIdentities(sessionID, identities: [identity])
        #expect(throws: ChauffeurError.self) { try claims.beginRemoval(removalID, path: "/tmp/renamed", worktreeIDs: [], gitIdentity: identity, sessions: []) }
        claims.endLaunch(sessionID)
        try claims.beginRemoval(removalID, path: "/tmp/renamed", worktreeIDs: [], gitIdentity: identity, sessions: [])
        try claims.beginLaunch(sessionID, paths: ["/tmp/previous-name"], worktreeID: nil)
        #expect(throws: ChauffeurError.self) { try claims.setGitIdentities(sessionID, identities: [identity]) }
    }
}
