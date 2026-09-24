import Foundation
import Testing
@testable import ChauffeurCore

struct WorktreeNavigationTests {
    private func session(folder: ProjectFolder, project: Project, directory: String, worktreeID: UUID? = nil, state: SessionState = .running, createdAt: Date = Date()) -> Session {
        let set = PresetSet(name: "Set")
        let preset = AgentPreset(setID: set.id, name: "Agent", kind: .codex, executable: "/bin/cat", configurationDirectory: "/tmp")
        var value = Session(projectID: project.id, groupID: project.groups[0].id, title: "Session", launch: LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat", executableVersion: "1", workingDirectory: directory, additionalPaths: []), folderID: folder.id)
        value.worktreeID = worktreeID; value.state = state; value.createdAt = createdAt
        return value
    }

    @Test func reorderedTabsPersistAndKeepOtherCheckoutsAndNewSessions() throws {
        let project = Project(name: "P", presetSetID: UUID())
        let folder = ProjectFolder(path: "/tmp/repo")
        let first = session(folder: folder, project: project, directory: "/tmp/repo")
        let second = session(folder: folder, project: project, directory: "/tmp/repo")
        let third = session(folder: folder, project: project, directory: "/tmp/repo")
        let otherCheckout = UUID()
        var state = WindowState(projectID: project.id)
        state.sessionTabOrder = WorktreeSessions.movingTab(first.id, to: third.id,
            displayed: [first.id, second.id, third.id], savedOrder: [otherCheckout])
        let restored = try JSONCoding.decode(WindowState.self, from: JSONCoding.encode(state))
        #expect(restored.sessionTabOrder == [otherCheckout, second.id, third.id, first.id])
        let newSession = session(folder: folder, project: project, directory: "/tmp/repo")
        let ordered = WorktreeSessions.orderedTabs([first, second, third, newSession], savedOrder: restored.sessionTabOrder)
        #expect(ordered.map(\.id) == [second.id, third.id, first.id, newSession.id])
        #expect(WorktreeSessions.selection(in: ordered.filter { $0.id != first.id }, selectedID: first.id, previousOrder: ordered.map(\.id)) == third.id)
        #expect(WorktreeSessions.movingTab(otherCheckout, to: first.id, displayed: ordered.map(\.id), savedOrder: restored.sessionTabOrder) == restored.sessionTabOrder)
        let movedBack = WorktreeSessions.movingTab(first.id, to: second.id, displayed: ordered.map(\.id), savedOrder: restored.sessionTabOrder)
        #expect(movedBack == [otherCheckout, first.id, second.id, third.id, newSession.id])
    }

    @Test func olderWindowRecordsDefaultToUnsortedTabs() throws {
        var value = try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(WindowState(projectID: UUID())))
        if case .object(var fields) = value {
            fields.removeValue(forKey: "sessionTabOrder"); fields.removeValue(forKey: "closedSessionTabs"); value = .object(fields)
        }
        let restored = try value.decode(WindowState.self)
        #expect(restored.sessionTabOrder.isEmpty)
        #expect(restored.closedSessionTabs.isEmpty)
    }

    @Test func closedTabsSurviveARestart() throws {
        var state = WindowState(projectID: UUID())
        let closed = [UUID(), UUID()]
        state.closedSessionTabs = closed
        let restored = try JSONCoding.decode(WindowState.self, from: JSONCoding.encode(state))
        #expect(restored.closedSessionTabs == closed)
        state.closedSessionTabs = [closed[0], closed[0]]
        #expect(throws: (any Error).self) { try state.validate() }
    }

    @Test func sessionsGroupByWorktreeRecordThenWorkingDirectory() throws {
        var project = Project(name: "P", presetSetID: UUID())
        project.addFolder(ProjectFolder(path: "/tmp/repo"))
        let folder = project.folders[0]
        let tree = Worktree(projectID: project.id, folderID: folder.id, repositoryID: UUID(), path: "/tmp/worktrees/feature", repositoryPath: folder.canonicalPath, branch: "feature", baseCommit: "abc", managed: true)
        let moved = Worktree(projectID: project.id, folderID: folder.id, repositoryID: UUID(), path: "/tmp/worktrees/moved", repositoryPath: folder.canonicalPath, branch: "moved", baseCommit: "abc", managed: true)
        let now = Date()
        let main = session(folder: folder, project: project, directory: folder.canonicalPath, createdAt: now)
        let finishedMain = session(folder: folder, project: project, directory: folder.canonicalPath, state: .exited, createdAt: now.addingTimeInterval(-60))
        let byRecord = session(folder: folder, project: project, directory: "/tmp/worktrees/feature", worktreeID: tree.id)
        // Launched before its worktree record existed: only the directory matches.
        let byDirectory = session(folder: folder, project: project, directory: "/tmp/worktrees/feature")
        // Its record still exists at another path, so the old directory does not claim it.
        let relocated = session(folder: folder, project: project, directory: "/tmp/worktrees/feature", worktreeID: moved.id)
        var otherFolder = Project(name: "Q", presetSetID: UUID()); otherFolder.addFolder(ProjectFolder(path: "/tmp/repo"))
        let foreign = session(folder: otherFolder.folders[0], project: otherFolder, directory: folder.canonicalPath)
        let all = [finishedMain, main, byRecord, byDirectory, relocated, foreign]
        let mainSessions = WorktreeSessions.sessions(all, folder: folder, path: folder.canonicalPath, worktrees: [tree, moved])
        #expect(mainSessions.map(\.id) == [main.id, finishedMain.id])
        let feature = WorktreeSessions.sessions(all, folder: folder, path: "/tmp/worktrees/feature", worktrees: [tree, moved])
        #expect(Set(feature.map(\.id)) == [byRecord.id, byDirectory.id])
        #expect(WorktreeSessions.sessions(all, folder: folder, path: "/tmp/worktrees/moved", worktrees: [tree, moved]).map(\.id) == [relocated.id])
        #expect(WorktreeSessions.live(mainSessions).map(\.id) == [main.id])
        #expect(WorktreeSessions.finished(mainSessions).map(\.id) == [finishedMain.id])
    }

    @Test func removedSelectionFallsBackToNearestLiveTabOnTheLeft() {
        let project = Project(name: "P", presetSetID: UUID())
        let folder = ProjectFolder(path: "/tmp/repo")
        let left = session(folder: folder, project: project, directory: folder.canonicalPath)
        let closing = session(folder: folder, project: project, directory: folder.canonicalPath)
        let right = session(folder: folder, project: project, directory: folder.canonicalPath)
        let order = [left.id, closing.id, right.id]
        #expect(WorktreeSessions.selection(in: [left, right], selectedID: closing.id, previousOrder: order) == left.id)
        #expect(WorktreeSessions.selection(in: [right], selectedID: closing.id, previousOrder: order) == right.id)
        #expect(WorktreeSessions.selection(in: [left, right], selectedID: right.id, previousOrder: order) == right.id)
        #expect(WorktreeSessions.selection(in: [], selectedID: closing.id, previousOrder: order) == nil)
    }

    @Test func missingSelectionAlwaysSelectsAnAvailableSession() {
        let project = Project(name: "P", presetSetID: UUID())
        let folder = ProjectFolder(path: "/tmp/repo")
        let finished = session(folder: folder, project: project, directory: folder.canonicalPath, state: .exited)
        let live = session(folder: folder, project: project, directory: folder.canonicalPath)
        #expect(WorktreeSessions.selection(in: [finished, live], selectedID: nil) == live.id)
        #expect(WorktreeSessions.selection(in: [finished], selectedID: nil) == finished.id)
        #expect(WorktreeSessions.selection(in: [finished, live], selectedID: finished.id) == finished.id)
        #expect(WorktreeSessions.selection(in: [finished, live], selectedID: UUID(), previousOrder: [finished.id, live.id]) == live.id)
    }

    @Test func legacyWindowRecordsDecodeAndNewFieldsRoundTrip() throws {
        let projectID = UUID(), sessionID = UUID()
        let legacy = """
        {"id":"\(projectID.uuidString)","tabs":["\(sessionID.uuidString)"],"selectedSessionID":"\(sessionID.uuidString)","splitSessionID":null,"sidebarVisible":true,"wasOpen":true}
        """
        let decoded = try JSONCoding.decode(WindowState.self, from: Data(legacy.utf8))
        #expect(decoded.tabs == [sessionID] && decoded.selectedSessionID == sessionID)
        #expect(decoded.sidebarMode == .repositories && decoded.selectedFolderID == nil && decoded.selectedWorktreePath == nil)
        try decoded.validate()
        var state = WindowState(projectID: projectID)
        state.sidebarMode = .sessions; state.selectedFolderID = UUID(); state.selectedWorktreePath = "/tmp/worktrees/feature"; state.selectedSessionID = sessionID
        let restored = try JSONCoding.decode(WindowState.self, from: JSONCoding.encode(state))
        #expect(restored == state)
        var relative = state; relative.selectedWorktreePath = "worktrees/feature"
        #expect(throws: ChauffeurError.self) { try relative.validate() }
    }

    @Test func shellLaunchRequestsAreOptionalForOlderClients() throws {
        let request = LaunchRequest.shell(projectID: UUID(), groupID: UUID(), folderID: UUID(), title: "Shell · main")
        #expect(request.launchKind == .shell && request.allowSharedCheckout && !request.coordinationEnabled)
        let decoded = try JSONCoding.decode(LaunchRequest.self, from: JSONCoding.encode(request))
        #expect(decoded.launchKind == .shell)
        let legacy = LaunchRequest(projectID: UUID(), groupID: UUID(), presetID: UUID(), folderID: UUID(), title: "Agent")
        #expect(try JSONCoding.decode(JSONValue.self, from: JSONCoding.encode(legacy))["kind"] == .null)
        // A request written by a client that predates `kind` still launches an agent.
        let older = """
        {"projectID":"\(UUID().uuidString)","groupID":"\(UUID().uuidString)","presetID":"\(UUID().uuidString)","folderID":"\(UUID().uuidString)","additionalFolderIDs":[],"title":"Agent","allowSharedCheckout":false,"coordinationEnabled":true,"retryKey":"\(UUID().uuidString)"}
        """
        #expect(try JSONCoding.decode(LaunchRequest.self, from: Data(older.utf8)).launchKind == .agent)
    }

    @Test func agentLaunchRequestsDefaultToBasicTerminalMode() throws {
        // Messaging and delegation are experimental: a caller that omits a choice must not enable them.
        let implicit = LaunchRequest(projectID: UUID(), groupID: UUID(), presetID: UUID(), folderID: UUID(), title: "Agent")
        #expect(!implicit.coordinationEnabled)
        let explicit = LaunchRequest(projectID: UUID(), groupID: UUID(), presetID: UUID(), folderID: UUID(), title: "Agent", coordinationEnabled: true)
        #expect(explicit.coordinationEnabled)
        // The choice survives the round trip used for retries.
        #expect(try JSONCoding.decode(LaunchRequest.self, from: JSONCoding.encode(explicit)).coordinationEnabled)
    }

    @Test func shellPresetsSkipCLIEnvironmentAndArgumentPolicy() throws {
        let shell = AgentPreset(setID: UUID(), name: "Shell", kind: .shell, executable: "/bin/zsh", configurationDirectory: "/tmp")
        var value = shell; value.arguments = ["-l", "--anything-goes"]
        try value.validate()
        let environment = try LaunchPolicy.environment(base: ["PATH": "/usr/bin", "CODEX_HOME": "/bad"], preset: value, projectID: UUID(), sessionID: UUID(), token: "secret")
        #expect(environment["CODEX_HOME"] == nil && environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(environment["CHAUFFEUR_SESSION_TOKEN"] == nil && environment["CHAUFFEUR_SESSION_ID"] != nil)
        #expect(!CLIKind.shell.isAgent && CLIKind.codex.isAgent && CLIKind.shell.displayName == "Shell")
    }
}
