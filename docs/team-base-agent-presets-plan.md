# Base agent presets and team configuration

Status: implemented, 2026-09-18. Verification details in `metadata-and-presets.md`. Branch: `plan/team-base-agent-presets`.

## Intended behavior

Base presets describe how an agent starts. Teams supply its configuration directory. Projects select a team, and every new terminal uses that team's configuration.

| Scope | Configurable fields |
| --- | --- |
| Base agent preset | Display name, harness (Claude Code or Codex), executable, launch arguments |
| Team | Name, config directory for each harness, Use all base agents / Custom, existing default-team choice |
| Custom team agent | Independent copy of a base preset; editable name, harness, executable and arguments |
| Project | Assigned team |

Harness environment variable names are fixed: `CLAUDE_CONFIG_DIR` for Claude Code and `CODEX_HOME` for Codex. The team edits the directory value, not the variable name. Configuration directories do not belong to either base presets or custom agents.

Confirmed: adding a base agent to a Custom team creates an independent copy. Later base edits, archival or removal do not change that copy. Its optional source ID is provenance only.

Use all base agents is live inheritance: adding, editing or archiving a base preset affects future launches in every team using that mode. It does not require copying records into each team. New teams default to this mode. Custom mode exposes only the team's selected copies and permits multiple differently named copies of the same base preset.

Example: Work and Personal both inherit “Claude”, “Claude Opus”, “Codex” and “Codex YOLO”. Both Claude variants use their team's Claude directory; both Codex variants use their team's Codex directory. Editing the global “Claude Opus” arguments updates both teams. A custom copy in Work remains unchanged.

## Confirmed decisions

1. Custom agents are independent copies of base presets.
2. A blank team directory uses the harness's normal default, with the effective path shown in the UI. Resolve that default centrally and record it for resume; do not inherit an arbitrary config variable from the launching process. Verify default-path behavior against the supported harnesses during implementation.
3. Preserve and migrate existing metadata. Conflicts are not expected; if existing agents disagree on a directory for the same harness, pick the first. Define first deterministically by preset name, then UUID, preferring active presets and using archived presets only when no active preset exists for that harness. No conflict-resolution prompt is required.

## Proposed interaction details

- Settings has separate Base Agent Presets and Teams sections. Base editors have no config directory field. Teams show both harness directory fields regardless of which presets are enabled.
- All-base mode shows the effective presets with a route to edit the global definition. Custom mode offers Add from Base, edit, duplicate and remove.
- On first switching to Custom, seed copies of the currently available base agents so the list remains familiar. Remap the project’s last-used choice to its copy. Switching back to all-base retains custom definitions inactive; returning to Custom restores them. Remap or clear stale last-used selections using the resolver.
- Use last-successful-agent → first available selection order. Teams have no default agent preset. The default team still only supplies the initial project assignment; changing the global default does not reassign existing projects.
- Add a persistent `Team: Work` control in the project window toolbar, visible with the sidebar collapsed. Its popover shows both variable names and effective directory values, and offers Edit Team and Change Project Team. Keep the existing sidebar team label consistent.
- The new-agent sheet shows the resolved configuration directory. Shell launches use both team variables even when Custom contains no agents of one harness or no agents at all.
- Team/project changes apply to new sessions. Existing sessions retain their launch configuration; session details show the team and paths captured at launch, including when the project's current team differs.
- Empty base catalogs/custom lists disable agent launch with an actionable empty state. They still permit shells when the project's team is valid. Missing/archived teams have an explicit recovery state.

## Model and resolution

The base record and compatible team-local record contain name, agent harness, executable and argument array. A shell is a launch kind, never a configurable agent harness.

- `BaseAgentPreset`: stable UUID, definition, revision and archived state, stored globally under `base-agent-presets/`.
- Team: retain the current `PresetSet` ID and storage location initially; add agent selection mode and per-harness directory settings. A broad rename of `presetSetID` can be a separate cleanup.
- Team custom agent: stable UUID, team ID, independent definition, revision/archived state and optional source base ID. Retain team-local storage.
- `StoreSnapshot.agents(in:)`: the shared ChauffeurCore resolver produces effective `AgentPreset` values with team identity, base provenance/revision and directory. Keeping the compatible value type avoids unnecessary changes to launch consumers.

Use a base UUID directly for an inherited choice and a new UUID for each custom copy. Always resolve and validate IDs in the project's team context; a globally valid base ID is unavailable to a Custom team unless represented by its own copy. Avoid manufacturing a different base UUID for every team.

Keep persisted editable definitions separate from launch snapshots. New snapshots capture effective executable, arguments, harness, config paths/environment selection, team identity/name/revision and definition revision. Preserve legacy snapshot decoding. Do not serialize the complete child environment or credentials into metadata.

All availability, defaults, remembered choices and reference checks must use the shared resolver. A base edit advances its own revision; it need not rewrite every inheriting team's file. Observe base changes so all affected windows and remote inventories refresh.

## Launch and environment behavior

Build child environments from the existing sanitized login environment, then apply the team's configuration variables. The team is the only editable authority for those variables. Proposed: apply both team harness variables to agent terminals as well as shells, so manually launching either harness from a terminal uses the same team.

Preserve the existing stripping of inherited provider/auth/session variables. Preserve managed launch argument validation and explicit argument arrays; executable/argument customization does not bypass Chauffeur's managed working-directory, resume or coordination behavior.

An explicitly configured missing/inaccessible directory must never be silently omitted and fall back to another account. Validate the selected harness before agent launch. For shells, preserve both explicit team values and show a directory problem without silently substituting defaults; shell startup itself need not require the agent directories to exist. Canonicalize available paths and preserve a usable absolute configured path when missing. Unrelated harness directory failures should not block a valid agent launch.

The current terminal preamble prints exports but is not what applies them: the environment is passed to the child. Keep these consistent. Test startup scripts that assign config variables and establish how shell integration reapplies the team values before the first prompt; simply injecting variables before a login shell may be insufficient.

Agent resume uses captured configuration. Shell snapshots capture both variables for history, but shell resume remains unsupported; open a new shell to use current settings. Changing a team must not silently move an agent conversation to another configuration directory.

Coordination skill status/install/remove must take team + harness context (or a resolved agent), because a global base preset no longer identifies a config directory. Do not install once per variant when several presets share a team directory.

## Existing code affected

| Area | Files / responsibilities |
| --- | --- |
| Records and snapshots | `Sources/ChauffeurCore/Records.swift`, `LaunchConfiguration.swift`, `FileStore.swift` |
| Persistence and reference validation | `FileStore.swift`, `StoreReferences.swift`, metadata watcher behavior |
| Environment | `ShellAgentEnvironment.swift`, `Validation.swift` (`LaunchPolicy`) |
| Runtime | `RuntimeCoordinator.swift`: launch, resume, save APIs, defaults, skill operations, coordination context and delegation validation |
| CLI launch assembly | `Sources/ChauffeurRuntimeKit/CLIAdapter.swift`: consume resolved snapshot values |
| Mac UI | `SettingsView.swift`, `SessionLaunchView.swift`, `ProjectWindow.swift`, `ProjectEditor.swift`, `AppModel.swift`, `CoordinationSkillView.swift`, session details |
| Remote/mobile | `RemoteInventoryBuilder.swift`, `RemoteOperationHandlers.swift`, remote DTOs as needed, `ChauffeurMobile/LaunchView.swift` |
| Local clients | `ChauffeurCtl`, launcher/API callers and integration fixtures consuming preset records |

Current pitfalls identified in source:

- `AgentPreset` owns both `setID` and `configurationDirectory`; all preset listings currently filter by team ownership.
- `ShellAgentEnvironment` chooses the default preset or first preset by name per harness. `shellAgentExports` then silently drops inaccessible paths.
- Agent launches and delegation validate against stored team-owned presets, so changing only the UI would leave inherited agents unlaunchable.
- Shell launches synthesize a “Shell” team; record the actual project team separately in the new snapshot.
- Agent resume uses its saved directory. The old shell branch in the resume implementation is unreachable: shell resume is rejected by both the runtime and CLI adapter.
- Remote inventory and remote launch preflight independently filter stored presets and must move to the same resolver.

## Migration plan

Preserve existing data:

1. Add a versioned, recoverable migration with backups and a completion marker. Stage and validate migrated records before activation; make interruption/retry idempotent and reject legacy-shaped team updates through the current service. Older application binaries do not understand this schema and must not be run against migrated data.
2. Keep team/project IDs, custom preset IDs, last-used choices. Ignore legacy default-preset fields. Convert existing teams to Custom so their available commands do not change unexpectedly.
3. Move unambiguous per-harness directories onto each team. Do not rewrite historical launch snapshots.
4. When presets of one harness have conflicting paths, choose the first using the deterministic order above and continue migration. Keep the original records in the migration backup and expose the selected directory in team settings. Historical snapshots and existing sessions retain their original paths; future launches use the selected team directory.
5. Seed the global catalog from deduplicated existing definitions (name, harness, executable, argument array), excluding config paths from equivalence. Keep team copies independent. For an empty installation, propose basic Claude and Codex entries; additional model/permission variants are user-configured.
6. Preserve optimistic concurrency, ownership checks, archived records and metadata watcher cache behavior. Deleting a team removes its local copies, never the base catalog or external config directories.


## Implementation sequence and acceptance

1. **Core model and resolver.** Implement inheritance/custom copies, stable identities, availability/default resolution and validation. Unit coverage: global additions/edits/archives propagate only in all-base mode; custom copies remain independent; cross-team custom IDs are rejected; empty catalogs and mode switches behave correctly.
2. **Persistence and migration.** Add records, APIs, snapshot compatibility, revisions, reference checks and watcher invalidation. Test stale writes, historical snapshots, interrupted migration and deterministic first-directory selection on conflicts.
3. **Runtime and clients.** Route launch, delegation, skill operations, remote inventory and launch validation through the resolver. Capture configuration for resume and unify shell/team env selection. Use fixture executables to verify argv/environment without real credentials or model requests.
4. **Settings and project UI.** Split global presets from team editing; implement copy workflows and mode switching; expose persistent team/config context. Adapt Mac/mobile launch choices and update fixture builders.
5. **Integration and documentation.** Update metadata/configuration docs and decision V2. Run relevant core/runtime/remote tests, then the full Swift suite and signed Mac build. Run native UI smoke checks for global edits across two teams, custom independence, project team switching and shell launch.

End-to-end acceptance: Work and Personal can use the same four base agents with different harness directories; new base agents appear immediately in both; a Custom team offers only its own copies; shell exports match the project team even with no enabled presets; changing team settings affects new terminals while running/resumed sessions retain their recorded configuration. Team context remains visible with the project sidebar hidden.
