# Metadata, agent presets, and launch defaults

Chauffeur stores editable JSON metadata under
`~/Library/Application Support/Chauffeur/preset-sets/` and `projects/`. Each
record has a stable UUID; directory names are assigned at creation and do not
change when you rename a project or team. The background service writes
files by atomic replacement and checks the version last read by an editor.
If a file changed or disappeared, reopen the editor before saving again.

## Agent Preteam revisions and defaults

Adding, changing, or archiving an agent preset advances its parent team's revision.
Changing the set's name, default, or archived state also advances it. Saving
unchanged values does not. The service owns revision increments, so editing a
agent preset through another window or the local API follows the same rules.

The team revision and the selected agent preset's values are copied into each launch
snapshot. Editing agent presets changes future launches; running sessions and their
recorded configuration directory remain unchanged. Native CLI configuration
files continue to follow the CLI's own behavior.

The new-session sheet first selects the project's last successfully launched
agent preset, then the team default, then the first available agent preset. Failed launches
do not replace this preference. Delegated children and conversation resumes do
not change the user's selection. Changing a project's team clears its
previous choice; a launch finishing from the old set cannot restore it.

An empty team can be saved and assigned to a project. The launch sheet
explains how to add an agent preset and keeps launch disabled. Missing and archived teams
have separate recovery instructions; the runtime also rejects unavailable
agent presets if a launch is requested directly through its API.

The choice is saved by updating that one field against current project metadata.
Concurrent project edits remain intact, and a stale editor must reload before
it can overwrite the resulting file.

Each individual file is replaced atomically. An agent preset update writes the new team
revision before its agent preset file, so an interrupted or failed second write can
leave an unused revision number. It cannot silently put new agent preset values under
an older revision. Hand edits are validated and reported without being rewritten;
when changing agent preset JSON by hand, update the team revision yourself if you want
that change reflected in the revision label.

## Reference checks and recovery

- Agent Presets must belong to the team whose directory contains them. Sessions,
  worktrees, and window state must belong to their containing project. Records
  with mismatched ownership or invalid JSON are skipped and reported with their
  path; Chauffeur preserves the files for repair.
- Missing defaults, teams, last-used agent presets, groups, folders, worktrees,
  parents, and window-tab targets are reported with the referring file's path.
  Well-formed historical records remain available. A missing team is never
  silently replaced by a different one.
- Launch snapshots do not need their old agent preset to remain in today's team.
  Archiving agent presets or groups, changing teams, and unregistering folders preserve
  historical references. Use **Archive** or **Remove** in the app rather than
  deleting referenced groups or folder entries from JSON.
- New writes reject defaults from another team, agent preset moves between teams,
  worktrees assigned to another folder, and known foreign window tabs in legacy
  records. Session membership stays fixed. A window's selected worktree path must
  be absolute; its legacy `tabs` and `splitSessionID` fields are decoded and
  emptied on the next write.
- Metadata files and child metadata directories are not followed through
  symlinks. Repository and CLI configuration paths can still use their normal
  canonical-path resolution.

Deleting a session file can leave a session retained by the runtime ledger. A
window may still open that runtime session; its missing file is reported as an
unresolved disk reference. Fix the relevant metadata or restore it from backup.

## Filesystem notifications

The runtime watches metadata while the app is closed. Its ordinary snapshot,
notification, and reconciliation checks consume pending file events and reuse
cached records and directory listings. An idle check does not read metadata from
disk. Changes under runtime storage or managed Git checkouts do not invalidate
the metadata cache.

A changed file invalidates its cached record and the directory lists needed to
discover additions, removals, or renames. Unchanged records remain cached. Atomic
editor replacements, project directory moves, copied-in directories, corruption
and later repair are handled by the same path. Runtime writes are visible on the
next refresh without waiting for an OS event.

Watching starts before the initial scan, so events arriving during a scan remain
queued. Dropped/coalesced events request a full rescan; a moved or unmounted watch
root also restarts the stream. These follow Apple's
[FSEvents recovery guidance](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).
If notifications cannot start, the metadata issues list reports that condition
and the store retries watching with a full scan every five seconds until it can
resume. Event paths retain their canonical spelling, including `/private/var`
and `/private/tmp` aliases.

File notifications are asynchronous. Background reconciliation consumes them
approximately once a second, while snapshot requests can consume them sooner.
Saves and launch preflight still perform an immediate disk reload and version
check; they do not rely on notification latency to reject stale writes.

## Verification

`Prototypes/editor_controls_smoke.py` exercises the native agent preset, project, and
group editors in an isolated signed Debug app. It creates three projects across
two teams, chooses configuration directories and executables through macOS
file panels, checks quoted arguments and literal hyphens, and verifies that
invalid paths or unfinished quotes remain unsaved. Repository discovery includes
a Git worktree with a `.git` file and a symlink loop. Explicit selection,
duplicate prevention, folder relinking, unregistering without deleting files,
group create/rename/archive/reopen/cancel, and project archive/reopen pass.

Creating a project now waits for its sheet to dismiss and its project window to
become visible before closing Welcome. The native check verifies the actual
visible window count; it reproduced the extra Welcome window before the fix.
An empty team permits project creation but disables session launch, and a
concurrent metadata change is preserved when a stale editor tries to save.
Evidence is under `.build/editor-controls-artifacts/`. These checks use temporary
repositories and profile directories, with no provider credentials or default
runtime writes. Native session/window and terminal-pointer regressions also pass.

`MetadataIntegrityTests` covers misplaced records, dangling references, retained
history, stale writes, default ownership, revisions, remembered choices, and
symlinked metadata directories. The native quick-session fixture also checks the
default selection after a successful launch and the unchanged launch snapshot
after an agent preset edit, plus the empty-team UI and runtime rejection.

`MetadataWatcherTests` uses real macOS notifications and I/O counters to check
idle cache reuse, one-file reloads, ignored runtime/Git activity, atomic file
replacement, corruption repair, directory moves/additions/removals, and recovery
after replacing the store root. An injected dropped-event condition verifies a
complete rescan. A runtime test edits and moves project metadata with no UI or
snapshot client attached, verifies that the background loop sees the changes,
and confirms the agent retains its process ID throughout.

The full Swift suite, signed Debug build, socket/runtime and worktree regression
fixtures, and native session-sheet fixture pass with the watcher enabled. Logs
are under `.build/metadata-watcher-*.log`. The current packaged version is tracked
in [implementation status](implementation-status.md#current-release--2026-09-16).

## Delete a team

In Settings → Agent Presets, select a team and click the trash button beside Edit,
or choose **Delete Team…** from its context menu. Confirm to remove the team and
its agent preset definitions. External CLI configuration directories and session
history are preserved. Switch all linked projects, including archived projects,
to another team before deleting. A concurrent edit requires reloading before retrying.
