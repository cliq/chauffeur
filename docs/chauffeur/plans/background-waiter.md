# Background waiter for idle coordinators

Status: planned (2026-09-23). Spike done; no product changes yet.

## Goal

A coordinator that is waiting for workers should cost nothing while it waits.
It should wake only when there is something to act on: a worker result, a peer
message, or a worker that stopped, failed or needs attention.

Today a coordinator stays inside its turn with `chauffeur_inbox({"waitSeconds":300})`.
In the 2026-09-23 CocoaPods orchestration (Codex 0.156.1, `gpt-6-astra`), that
turn re-entered the model about every 64 s. Each wake sent about 60k input tokens
(about 99.5% cached) and got 40–120 output tokens, roughly 3.6M input tokens an
hour. The cause is `ProgressWatcher`: the inbox wait returns on any change to a
worker's progress document, including the free-text `now` field, which workers
update often.

Non-goals:
- Chauffeur typing into an idle session's terminal. Messages stay mailbox data,
  as V4 requires.
- Changing message delivery states or the retry model.

## Evidence (2026-09-23)

All with the real TUIs and local mock providers
(`Prototypes/inbox_hooks/codex_background_probe.py`, `claude_background_probe.py`).
No accounts were used.

### Claude Code 2.1.280

| Check | Result |
| --- | --- |
| `run_in_background` Bash, then the turn ends | The command keeps running. |
| The command exits while the session is idle | Claude **starts a new turn by itself.** The turn's input is a system reminder with `<task-notification>` holding `task-id`, `output-file`, `status` and a one-line summary. The output itself is not inline; the model reads `output-file`. |
| Hooks on that wake | `UserPromptSubmit` fires, with `prompt` starting `<task-notification>`. |
| `Stop` payload while it runs | `background_tasks: [{"id", "type": "shell", "status": "running", "description", "command"}]`; after the wake it is `[]`. |
| Permissions | `Bash(sleep:*)` doesn't cover a compound command. The waiter needs an exact allowlist entry, or the user gets a permission prompt. |

### Codex 0.156.1

| Check | Result |
| --- | --- |
| `exec_command` with a short `yield_time_ms` | Returns "Process running with session ID …"; the command keeps running after the turn ends and completes. |
| The command exits while the session is idle | **No new turn.** Nothing wakes the session. |
| Unix socket connect from a command, `-s danger-full-access` | Works. |
| Same, `-s workspace-write` and `-s read-only` | `PermissionError: [Errno 1] Operation not permitted`. |

Consequences:
- The background waiter works for **Claude** coordinators only. A Codex
  coordinator has no idle wake apart from Chauffeur typing into it, so it keeps
  the in-turn inbox wait, made cheaper by the progress filter below.
- **Sandboxed Codex commands can't reach the runtime socket.** That already
  affects `implementation-progress` auto-registration in `workspace-write` and
  `read-only` Codex sessions. MCP and hooks are unaffected: they run outside the
  sandbox.
- A real model was not needed to answer these questions: waking is TUI behavior.
  Whether a real model follows the new coordinator guidance is checked in T6.

## Design

### 1. Progress wake filter (both providers)

`chauffeur_inbox` waits and the waiter wake on **meaningful** progress changes
only: a phase or step changing state (in particular to `blocked` or `done`), a
phase added or removed, or `percentComplete` crossing a phase boundary. Changes
to `now`, `updated`, `title` or `subtitle` don't wake. Results, messages and
worker state changes still wake immediately.

### 2. `chauffeurctl wait-for-work` (Claude coordinators)

- Authenticates with the inherited `CHAUFFEUR_SESSION_TOKEN` over the runtime
  socket, like progress registration. New IPC method `waitForWork`.
- Blocks until one of these happens for the caller:
  - a queued message (peer message or worker result);
  - a controlled worker exits, fails, is interrupted or needs attention;
  - a meaningful progress change (filter above), if `--progress` is given;
  - a timeout (default 60 min, maximum 4 h). It then exits so the coordinator can
    decide whether to wait again.
- Prints a compact report and exits 0:
  - worker results in full, up to 16 KiB in total. Those messages are delivered
    (`received`) by the same call that prints them, exactly like `chauffeur_inbox`;
    the coordinator acknowledges them afterwards;
  - for anything longer, or for peer messages, a count and "call chauffeur_inbox";
  - worker state changes as one line each (title, state, delegation ID).
  - Message text is task data; the report says so.
- One waiter per session: a new `waitForWork` call replaces the previous one,
  which exits with "replaced".
- Exits when its parent process is gone (`getppid()` changes or is 1), on
  SIGTERM, when the session is no longer live, or when its credential is revoked.
- Exit status 0 for work or timeout, 2 for "replaced or session ended", 1 for
  errors; the report explains which.
- Under a sandbox that blocks the socket it fails fast, with a message telling
  the coordinator to use `chauffeur_inbox` waits instead.

### 3. Claude launch integration

- Coordinated Claude sessions get an allowlist entry for the exact waiter
  command in the launch-scoped settings: `Bash(<ctl> wait-for-work:*)`, with the
  ctl path shell-quoted as in hooks. Nothing else is pre-approved.
- The skill tells Claude coordinators: after delegating, start
  `"<ctl>" wait-for-work` with `run_in_background: true` and end the turn. On the
  task notification, read the output file, act, and start a new waiter if work
  remains. The ctl path is taken from `CHAUFFEUR_CTL`, a new environment variable
  set for agent sessions.

### 4. Status while waiting (inspired by claude-monitor)

claude-monitor keeps a "background working" state for Claude sessions whose
`Stop` payload lists running `background_tasks`, ignoring open-ended monitor
types. It clears the state when the transcript records the task's completion.

Chauffeur can be more precise, because the waiter is its own process:
- While a `waitForWork` call is open for a session whose turn finished, the
  session state is a new `waitingForWork` ("Waiting for workers" on the tab), not
  `turnFinished`. No completion notification is sent for that Stop.
- The claude-monitor rule is the fallback for other background shell tasks: the
  Claude `Stop` hook (`inbox-hook --report-stop`) forwards the count of running
  non-monitor `background_tasks`. More than zero reports `backgroundWorking`
  ("Background task running") instead of `turnFinished`. The task-notification
  wake arrives as `UserPromptSubmit`, which already reports `running`.
- `HookPayload` gains `backgroundTasksActive`. Oversized payloads fall back to
  the top-level scanner, which skips arrays, so the count is then unknown and the
  old behavior applies.

### 5. Codex coordinators

- They keep `chauffeur_inbox({"waitSeconds":300})`, with the progress filter.
  At about 12 wakes an hour when workers don't change phase, that's roughly 5×
  cheaper than today.
- The Codex status gap seen on 2026-09-23 is fixed too: the tab said "Turn
  finished" during a long turn, because Codex status comes only from `notify`.
  The trusted `UserPromptSubmit`/`PostToolUse` hook (`inbox-hook --provider codex`)
  also reports `running`, using the same `--report-running` flag on both events.
- Sandboxed Codex sessions: the `implementation-progress` skill tells the agent to
  call `chauffeur_register_progress` over MCP when the script warns that it
  couldn't reach the runtime.

## Tasks

### T1: Progress wake filter
- Files: `ProgressWatcher.swift`, `ImplementationProgress` comparison helper.
- Tests: `now`/`updated` edits don't wake; phase/step state changes, added
  phases and blocked steps do. Existing `InboxWaitTests` still pass.

### T2: `waitForWork` IPC and `chauffeurctl wait-for-work`
- Files: `Ledger.swift` (non-delivering wait plus delivery of printed results),
  `RuntimeCoordinator.swift`, `CtlMain.swift`, `ChauffeurCore` report formatter.
- Tests: result, peer message, worker exit/failure/needs-attention, filtered
  progress, timeout, replacement, revoked credential, parent death, a result over
  16 KiB (counted, not printed, stays queued), delivery state after printing, and
  no bodies in any log.

### T3: Claude integration
- Allowlist entry in generated `settings.json`; `CHAUFFEUR_CTL` in agent
  environments; skill text in `chauffeur` and `chauffeur-orchestrator` (bump
  versions).
- Tests: `CLIAdapterTests` for the allowlist entry and quoting.

### T4: Status
- `waitingForWork` and `backgroundWorking` session states, tab text and colours,
  no completion notification while waiting, `HookPayload.backgroundTasksActive`,
  Codex `--report-running`.
- Tests: state transitions from hook events and waiter connect/disconnect; the
  UI shows the new states.

### T5: Codex and sandbox guidance
- Skill text for Codex coordinators and for sandboxed progress registration.

### T6: Acceptance
- Mock-provider smoke: a Claude coordinator delegates to a Codex worker, starts
  the waiter, ends its turn, and wakes exactly once with the result. The tab shows
  "Waiting for workers" meanwhile. No model requests happen while waiting.
- The same with a Codex coordinator using the filtered inbox wait: requests only
  on result or phase changes.
- One short real-model check per provider, with cheap models. It confirms a real
  model follows the guidance and wakes. Codex is run only if the account has quota.

## Decisions needed

1. Should the waiter deliver and print worker results (recommended), or only
   report that they arrived?
2. Default timeout: 60 min (recommended) or longer?
3. Should Codex coordinators get an opt-in "result wake" in which Chauffeur submits
   a follow-up prompt through the checked composer path? It is the only way to
   make an idle Codex coordinator free, and it does type into the terminal.
