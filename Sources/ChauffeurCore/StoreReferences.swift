import Foundation

/// Report broken links without deleting historical records or replacing a
/// user's selected IDs. Archived/unregistered targets still resolve history.
enum StoreReferences {
    static func errors(in snapshot: StoreSnapshot) -> [ChauffeurError] {
        var errors: [ChauffeurError] = []
        func require(_ condition: Bool, _ message: String, _ path: String, code: String = "unresolved_reference") {
            if !condition { errors.append(ChauffeurError(code, message, path: path)) }
        }
        for stored in snapshot.projects {
            let project = stored.value
            require(snapshot.presetSets.contains { $0.value.id == project.presetSetID }, "Project's team is missing", stored.path, code: "unresolved_preset_set")
            if let id = project.lastPresetID {
                require(snapshot.agents(teamID: project.presetSetID, includeArchived: true).contains { $0.id == id }, "Last-used agent preset is missing or belongs to another team", stored.path)
            }
        }
        for stored in snapshot.sessions {
            let session = stored.value
            let project = snapshot.projects.first { $0.value.id == session.projectID }?.value
            require(project != nil, "Session's project is missing", stored.path)
            require(project?.groups.contains { $0.id == session.groupID } == true, "Session's group is missing from its project", stored.path)
            require(project?.folders.contains { $0.id == session.folderID } == true, "Session's folder is missing from its project", stored.path)
            if let id = session.worktreeID {
                require(snapshot.worktrees.contains { $0.value.id == id && $0.value.projectID == session.projectID && $0.value.folderID == session.folderID }, "Session's worktree is missing or belongs to another project/folder", stored.path)
            }
            if let id = session.parentID {
                require(id != session.id && snapshot.sessions.contains { $0.value.id == id && $0.value.projectID == session.projectID && $0.value.groupID == session.groupID }, "Session's parent is missing or belongs to another group", stored.path)
            }
            // The launch snapshot deliberately does not resolve through today's
            // preset: edits, archival and project set changes must preserve it.
        }
        for stored in snapshot.worktrees {
            require(snapshot.projects.contains { $0.value.id == stored.value.projectID && $0.value.folders.contains { $0.id == stored.value.folderID } }, "Worktree's folder is missing from its project", stored.path)
        }
        for stored in snapshot.windows {
            let window = stored.value
            require(snapshot.projects.contains { $0.value.id == window.id }, "Window's project is missing", stored.path)
            if let id = window.selectedGroupID {
                require(snapshot.projects.contains { $0.value.id == window.id && $0.value.groups.contains { $0.id == id } }, "Window's selected group is missing from its project", stored.path)
            }
            for id in window.tabs {
                require(snapshot.sessions.contains { $0.value.id == id && $0.value.projectID == window.id }, "Window tab's session is missing or belongs to another project", stored.path)
            }
        }
        return errors
    }
}
