# Metadata, shared presets, and teams

Chauffeur stores editable JSON metadata in its Application Support directory.
Global launch definitions live in `base-agent-presets/`; team records and their
custom agents remain in `preset-sets/`; projects and history live in `projects/`.
Stable UUIDs identify records. The service uses atomic replacement and version
checks so a stale editor cannot overwrite another edit.

## Shared Agent Presets

Settings → Shared Agent Presets defines a name, agent (Claude Code or Codex),
executable and launch arguments. Configuration directories belong to teams.
Examples include Claude, Claude with `--model opus`, Codex and Codex with
`--yolo`. Existing managed-argument validation still applies.

Changes to a shared preset affect future launches in every team using all shared
presets. Each shared preset has its own revision; changing it does not rewrite team files.
Archiving a shared preset hides it from these teams while preserving existing sessions.

## Teams

Settings → Teams provides `CLAUDE_CONFIG_DIR` and `CODEX_HOME` directory values.
A blank value uses the normal agent default (`~/.claude` or `~/.codex`). The
project team popover and launch sheet show effective paths. Explicit directories
must be accessible before launching that agent. The app does not create them.
A missing default directory is left for the CLI to initialize normally.

New teams use **Use all shared presets**. Their available agents follow the global
catalog automatically. **Custom** uses independent copies with editable names,
agents, executables and arguments. **Add from Shared Presets…** creates a new copy;
subsequent shared preset edits do not affect it. Multiple copies of a shared preset are allowed.
Custom agents always use their team's directory for the selected agent.

The first switch from all-shared to Custom copies the available shared presets.
Switching back retains these custom definitions inactive; switching to Custom
again restores them. Archiving a custom agent removes it from launch choices.

Exactly one active team is the default while any team exists. It supplies the
initial selection for new projects. Changing the default does not move existing
projects. A project window's **Team: …** toolbar control remains visible when its
sidebar is hidden, shows both effective paths, and offers team/project editing.

Both team variables are passed to every new agent and shell terminal, even if
Custom has no agents of a agent. Missing explicit shell paths remain exported
so typing a CLI cannot silently fall back to a different account. For zsh, a
private startup wrapper sources normal user startup files and reapplies the team
values afterward; it never edits those files. Other shells receive the same
initial environment and retain their own startup-file behavior.

## Launch defaults and history

Agent selection prefers the project's last successful choice, then its team's
default, then the first available agent. Unavailable choices fall back within the
same team. Changing the project team clears its remembered selection. Shells do
not require enabled agent presets, but do require an active project team.

Launch snapshots capture the resolved definition, shared preset revision when inherited,
team identity/revision and both configuration values. Edits affect future launches;
running sessions and resumed agent conversations keep their recorded configuration.
Shell sessions cannot be resumed; open a new shell to use current team settings.
Native CLI files still follow the CLI's own behavior.

Coordination skill operations resolve a team and agent together. Installation
applies to the agent directory shared by all matching variants in that team.

## Migration

On service startup, legacy teams become Custom, preserving team, project, preset
and default/last-used IDs. Historical sessions are not rewritten. Distinct legacy
launch definitions seed the shared catalog, excluding their configuration paths
from deduplication. Fresh installations start with basic Claude and Codex entries.

Each team's directory comes from its first preset of that agent, preferring
active presets, ordered by name with UUID as a tie-breaker. This also resolves
conflicts automatically. Original team and preset records are backed up under
`migrations/team-agents-v2/`. The migration is recoverable per team and repeatable;
it never copies credentials or modifies external CLI directories. Legacy preset
path fields remain readable for compatibility but no longer control launches
once their team has migrated.

## Reference checks and recovery

- Custom agent presets must belong to the team whose directory contains them. Shared presets are global. Sessions,
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
- New writes resolve defaults against the team’s effective catalog and reject custom agent moves between teams,
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

## Refactor verification

2026-09-18: all 284 Swift tests, the signed Debug build and
`Prototypes/runtime_smoke.py` pass. The native team smoke script could not run
because macOS Accessibility access was unavailable. No real provider requests
were used for these checks.

`TeamAgentsTests` covers inheritance, independent copies, mode switching, default
paths and migration. `TeamAgentRuntimeTests` launches fixture processes and zsh
terminals, checks startup-file overrides, verifies immutable resume configuration,
and exercises inherited presets through remote inventory and launch.

`Prototypes/team_agents_smoke.py` exercises native shared-preset/team editing, Add from
Shared Presets and the project team control in an isolated signed app. It requires existing
macOS Accessibility permission and exits before opening the app when unavailable.

## Previous editor verification

The following describes the pre-refactor editor fixture; its per-preset directory
controls have been replaced by team fields. Use `team_agents_smoke.py` for the new
flow.


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

In Settings → Teams, select a team and click the trash button beside Edit,
or choose **Delete Team…** from its context menu. Confirm to remove the team and
its agent preset definitions. External CLI configuration directories and session
history are preserved. Switch all linked projects, including archived projects,
to another team before deleting. A concurrent edit requires reloading before retrying.
