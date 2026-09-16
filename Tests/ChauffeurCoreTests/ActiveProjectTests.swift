import Foundation
import Testing
@testable import ChauffeurCore

struct ActiveProjectTests {
    private func session(_ project: Project, state: SessionState = .running, age: TimeInterval = 0) -> Session {
        let set = PresetSet(name: "Set")
        let preset = AgentPreset(setID: set.id, name: "Agent", kind: .codex, executable: "/bin/cat", configurationDirectory: "/tmp")
        var session = Session(projectID: project.id, groupID: project.groups[0].id, title: "Session",
            launch: LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/cat", executableVersion: "1", workingDirectory: "/tmp", additionalPaths: []), folderID: UUID())
        session.state = state
        session.createdAt = Date(timeIntervalSince1970: age)
        return session
    }

    @Test func listsEveryLiveStateOncePerProjectAndExcludesFinishedAndOrphanedSessions() {
        let alpha = Project(name: "Alpha", presetSetID: UUID())
        let beta = Project(name: "Beta", presetSetID: UUID())
        let ended = Project(name: "Ended", presetSetID: UUID())
        let empty = Project(name: "Empty", presetSetID: UUID())
        let orphan = Project(name: "Orphan", presetSetID: UUID())
        let live = SessionState.allCases.filter(\.isLive).map { session(alpha, state: $0) }
        let finished = SessionState.allCases.filter { !$0.isLive }.map { session(ended, state: $0) }
        let entries = ActiveProject.entries(projects: [beta, ended, empty, alpha],
            sessions: live + finished + [session(beta), session(orphan)], windows: [])
        #expect(entries.map(\.name) == ["Alpha", "Beta"])
        #expect(entries.map(\.sessionCount) == [5, 1])
        #expect(entries[0].route.projectID == alpha.id)
        #expect(live.contains { $0.id == entries[0].route.sessionID })
        #expect(ActiveProject.entries(projects: [empty], sessions: [], windows: []).isEmpty)
    }

    @Test func restoresSelectedLiveSessionAndFallsBackWhenItEnds() {
        let project = Project(name: "Project", presetSetID: UUID())
        let older = session(project, age: 1)
        var selected = session(project, age: 2)
        var window = WindowState(projectID: project.id)
        window.selectedSessionID = selected.id
        let entries = ActiveProject.entries(projects: [project], sessions: [older, selected], windows: [window])
        #expect(entries.first?.route.sessionID == selected.id)
        selected.state = .exited
        let fallback = ActiveProject.entries(projects: [project], sessions: [selected, older], windows: [window])
        #expect(fallback.first?.route.sessionID == older.id)
        #expect(fallback.first?.sessionCount == 1)
    }
}
