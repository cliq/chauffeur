# Coordination skills

Chauffeur automatically links both bundled skills when the runtime starts, when
setup completes, and when a team is created or its configuration directories
change. **Settings → Agent Presets → Chauffeur Skill…** shows their health,
destinations, versions, and guidance. **Refresh** also repairs missing links.
There is no manual install, update, removal, or migration step.

The `chauffeur` skill explains discovery, messages, bounded inbox waiting,
authorized delegation, attributed results, follow-up turns, retained-history
closure, retries, and recovery. `chauffeur-orchestrator` executes a saved plan
through one visible worker at a time. Its six role references provide freely
overridable model/reasoning suggestions. Installing guidance does not launch an
agent or join a session to a group.

## Waiting during orchestration

The coordinator uses `chauffeur_inbox` with `waitSeconds: 300`. The runtime
suspends that call until message arrival, a worker state change, registered
worker progress changes, or the deadline;
it does not poll SQLite. Registered progress files use filesystem events that
handle atomic replacement; timestamp-only updates are ignored. Delegation status
includes the worker’s `progress.jsonPath` for the coordinator to inspect. Processed message IDs belong in the next call's
`acknowledge` array. An empty response prompts a delegation status check, not a
claim of completion. An idle coordinator still needs a new turn to resume work.

Launch and resume configure only Chauffeur's MCP server with a six-minute tool
timeout: Codex's `mcp_servers.chauffeur.tool_timeout_sec=360` and Claude Code's
per-server `timeout: 360000`. These settings follow the providers' documented
[Codex configuration](https://developers.openai.com/codex/config-reference) and
[Claude Code timeout behavior](https://code.claude.com/docs/en/env-vars).
Existing CLI processes retain their startup configuration; use shorter waits
until they are resumed or relaunched.

`CHAUFFEUR_INBOX_PROBE_DELAY=65 python3 Prototypes/orchestration_smoke.py`
verifies that an actual HTTP inbox request survives beyond 60 seconds and wakes
when a worker reports. It uses isolated fixture CLIs, without provider inference.

## Discovery paths

| CLI | Links |
| --- | --- |
| Codex | `~/.agents/skills/chauffeur` and `~/.agents/skills/chauffeur-orchestrator`, shared across Codex profiles |
| Claude Code | `<team Claude home>/skills/chauffeur` and `<team Claude home>/skills/chauffeur-orchestrator` |

Claude uses `~/.claude` when the team has no custom Claude directory. Active
teams sharing a directory share one installation. Archived teams do not create
new links. Changing or deleting a team leaves existing links intact because
other sessions may still use that directory.

These skills are also discoverable outside Chauffeur. CLI policies or disabled
skill settings can still prevent loading. Restart the CLI if discovery does not
refresh; existing conversations may retain guidance already loaded into context.
Codex documents shared user skills and symlink support in its
[skill documentation](https://learn.chatgpt.com/docs/build-skills).

## Managed source and conflicts

The runtime publishes the bundled catalog beneath
`<Chauffeur data directory>/managed-skills/`. For the installed app, this lives
in Chauffeur's Application Support directory. Every discovery link points
through `managed-skills/current/<skill>`. A complete catalog, including role
references, is written before `current` is atomically switched to it. Updating
Chauffeur and restarting its runtime updates all linked profiles together;
moving the app does not change the link destinations.

Catalogs have content-derived names and old catalogs remain available. Managed
source files are generated from the app bundle; edit the source repository and
rebuild to change them. Unexpected edits to an existing catalog are reported.
An unrelated file, directory, or link at a discovery destination is preserved
and shown as a conflict. Move the conflicting item aside, then Refresh. There
is intentionally no conversion of older copied installations.

A private `.chauffeur-skill.lock` serializes writers for each discovery directory.
Publishing has a separate lock in the managed source. Native configuration,
credentials, repository instructions, and unrelated skills remain unchanged.

## Verification

```sh
swift test --no-parallel --filter 'SkillInstaller|DefaultTeamRuntime'
swift build
python3 Prototypes/skill_installation.py
```

Tests cover shared catalog updates including references, missing-link repair,
foreign and broken link conflicts, deduplication, startup, team creation, and
team directory changes. The native fixture uses temporary profiles and a fixture
HOME, suppresses login-shell environment replacement, and requests metadata only.
It verifies that Codex discovers the symlinks across profiles while Claude's
skills remain scoped to its configured home. It also checks missing-link repair.
`CHAUFFEUR_RUNTIME_BINARY` can select a packaged runtime for the same check.

Validation on 2026-09-22: the full sequential package suite passed 376 tests
across 75 suites; the final installer suite passed five tests (including four
conflict variants). Native metadata discovery passed on Codex 0.155.1 and Claude
Code 2.1.278. The signed Debug app build and signature verification passed.
