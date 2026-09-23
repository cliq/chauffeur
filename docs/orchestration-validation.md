# Orchestration validation

The implementation extends Chauffeur's existing project/group MCP connection.
Both **Chauffeur Orchestrator** and its operational **Chauffeur** dependency
are linked automatically; the preset’s **Chauffeur Skill…** sheet shows status. Ask the
coordinator to execute a saved plan with that skill. Workers run one at a time
in the explicitly selected checkout, report results, and remain visible for
review or intervention.

Create/Edit Agent Preset has editable model and reasoning suggestions synchronized
with launch arguments. Custom values and invalid argument text can be saved.
Warnings explain execution constraints; saving does not promise the provider can
run that configuration. New Session and MCP delegation can override model and
reasoning without changing the preset. Delegated workers enforce native YOLO
permissions at launch.

## Reproducible checks

```sh
swift test --no-parallel
make build
python3 Prototypes/orchestration_smoke.py
python3 Prototypes/runtime_smoke.py
```

The dedicated orchestration fixture uses the real runtime, Unix IPC, HTTP MCP,
SQLite ledger, and tmux, with a local fake CLI and no inference. It checks an
existing worktree, model/effort overrides, worker-only YOLO normalization,
messages and reports, safe refusal of unverified follow-up input, closure,
replacement, coordinator recovery, forced closure with a missing-history warning,
stable retries, runtime restart, and preserved history.

The unit suites cover saved malformed arguments, override precedence, scoped
control and recovery, turn/result attribution, durable receipts, predecessor
termination, protected captures under budget pressure, and shared skill publication
with automatic links for both skills and all role references. The native app build checks the SwiftUI
integration. Process-heavy tests are run sequentially because simultaneous Git
and tmux fixtures can exhaust the existing process runner's one-second pipe-drain
window on this machine.

## Native provider check

```sh
python3 Prototypes/native_orchestration.py \
  --codex-profile "$HOME/.codex" \
  --claude-profile "$HOME/.claude"
```

This is an opt-in inference check with existing authenticated profiles. It starts
an isolated runtime and empty temporary repository, launches a real coordinator
that delegates to the other provider, and has the worker call MCP discovery and
result reporting. It submits a correction through the new follow-up operation,
checks the new turn's result, and closes with retained history. Both provider
directions run. Trust prompts are accepted only for the probe's own empty
checkout as fixture setup, not as a product feature.

Private runtime logs, captured screens, and a machine-readable success summary
are written under `.local/native-orchestration/`. Fixture grants remain in the
private temporary root named by `fixture-path.txt`; no credentials or grants are
printed in the report. The probe stops only its own sessions and runtime.

Follow-up checks provider identity and live terminal readiness, without a version
allowlist. Unknown native composer layouts return
an unavailable state; busy sessions and actual drafts are never treated as a
result-ready input field. The coordinator may choose a fresh replacement.
Ordinary messages remain queued mailbox data and do not start turns. A terminal
submission receipt is distinct from an attributed worker result, and uncertain
submission is never automatically replayed.

## Recorded evidence — 2026-09-22

The complete sequential package suite passed 376 tests across 75 suites before
final focused regressions; the final focused run passed another 26 tests across
six suites. The signed Debug app built successfully.
The original runtime fixture, dedicated orchestration fixture, and native skill
installation/discovery/isolation/removal fixture all passed.

The authenticated native orchestration fixture passed in both directions:

| Coordinator | Worker | Worker overrides | Result |
| --- | --- | --- | --- |
| Codex 0.155.1 | Claude Code 2.1.278 | `sonnet`, `medium` | Delegation, messages, reports, same-session correction, retry, retained close |
| Claude Code 2.1.278 | Codex 0.155.1 | `gpt-6-astra`, `medium` | Delegation, messages, reports, same-session correction, retry, retained close |

Both workers used delegated YOLO mode. Corrections included multiline input and
produced a distinct attributed turn result. These model names record the probe's
choices; they are neither a fixed allowlist nor a promise of availability in
other accounts.

The subsequent automatic-symlink installer replaces the original manual copy
installer. Native Codex 0.155.1 and Claude 2.1.278 metadata discovery passed with
symlinked catalogs, along with profile scope and missing-link repair.

Provider errors that leave an interactive CLI open (for example Codex model
capacity errors) currently have no dedicated runtime-to-coordinator failure
notification. Worker MCP reporting cannot cover failures that prevent the model
from running. Codex turn-completion notifications are not evidence of success;
structured provider-failure integration remains separate work.

## Inbox reminders — 2026-09-23

```sh
swift build
python3 Prototypes/codex_inbox_hooks_smoke.py
python3 Prototypes/cross_provider_inbox_smoke.py
```

Both checks use the real runtime, the real Claude Code and Codex TUIs in the
runtime's tmux, and local mock providers scripted per prompt. They need no
account and send no inference. Each session uses a throwaway profile; the
checks refuse to type into a session whose configuration directory is not its
mock profile, and they compare `~/.codex` and `~/.claude/settings.json` before
and after.

| Check | Codex 0.156.1 | Claude Code 2.1.280 |
| --- | --- | --- |
| Hook trust | Preflight trusts Chauffeur's session-flag hooks; no review prompt | Launch-scoped `--settings` |
| Mail while busy (peer on the other provider) | One `PostToolUse` reminder, then `chauffeur_inbox` | One `PostToolUse` reminder, then `chauffeur_inbox` |
| Mail during the final answer | One `Stop` continuation | One `Stop` continuation |
| Idle recipient | Not woken; mail stays queued; reminded at the next prompt | — |
| Identity | `/new` followed; Resume reopens it; title-thread `notify` ignored | `/clear` during an active delegation followed; `/resume <id>` followed; Resume reopens it |
| Delegation across `/clear` | — | The Codex worker's result routes to the coordinator; its next prompt says "1 worker result" |
| Runtime restart mid-turn | — | One message, one reminder; nothing duplicated or lost |
| User configuration | Unchanged | Unchanged |

Claude's TUI labels the one intended continuation "Stop hook error: Chauffeur: …".
The check fails on any other hook error, including "Hook reported a different
native conversation". No real model was asked to act on a reminder in these
runs; the mocks call `chauffeur_inbox` when a reminder is present.

## Idle coordinators — 2026-09-23

```sh
swift build
python3 Prototypes/coordinator_wait_smoke.py
```

Real runtime, real Claude Code 2.1.280 and Codex 0.156.1 TUIs, local mock providers.

| Coordinator | How it waits | Result |
| --- | --- | --- |
| Claude Code | `chauffeurctl wait-for-work` in the background (discovery's `waitCommand`), then ends its turn | Pre-approved by Chauffeur's launch settings (no prompt). Tab shows "Waiting for workers"; no model requests while the Codex worker runs; one task-notification wake whose output holds the result, already acknowledged |
| Codex | Ends its turn after delegating | One "Chauffeur: 1 new worker result" prompt typed by Chauffeur when the worker reports; the coordinator reads its inbox |

Waiting inside `chauffeur_inbox` still works everywhere, and now wakes only on
worker milestones, not on "now doing" text. Spike evidence is in
`docs/chauffeur/plans/background-waiter.md`.
