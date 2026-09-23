# V4 — groups and delivery

Status: extended orchestration implementation; native acceptance evidence is recorded in docs/orchestration-validation.md.

## Decision

Use a runtime-owned SQLite ledger with WAL and FULL synchronization. Accept messages only after transaction commit. Persist scoped sessions, hashed grants, mailbox records and delegation reservations. Resolve project/group membership from the bearer token, not tool arguments or MCP transport IDs. The UI's Unix-socket API is separately protected by filesystem permissions and peer UID checks.

Message states distinguish queued, received by inbox integration, acknowledged, failed and cancelled. A repeated stable retry key returns the existing record; different content using the same key fails. Exited recipients keep their inbox. Only the actual recipient can acknowledge or reply as recipient. Messages never flow to PTY input.

Delegation reserves a durable child identity before launching, shares the normal launch path, defaults to a new worktree, limits live children to four by default, and rejects recursive delegation. A reported result does not stop the child's terminal or stop counting its live process. Failed operations preserve the delegation and any created worktree.

## Evidence

`LedgerTests` checks two groups in one project and another project sharing a group UUID, guessed message IDs, foreign recipients, revocation, no default authorization, restart visibility, idempotency conflicts, recipient-only acknowledgement, reservation limits, depth limits and result attribution. `runtime_smoke.py` checks real HTTP requests, UI-independent runtime restart, duplicate launch request IDs, and persisted inbox state using fixture CLIs.

## Remaining gate evidence

Real Codex→Claude and Claude→Codex delegation while the UI is closed remains open. More integration cases are needed for crash windows during worktree creation/delegation, native approval prompts, long-running busy recipients, and parent termination. Result-message acceptance and delegation result updates share one transaction. Pruned completed messages retain retry tombstones so old retries cannot create new deliveries. The user will explicitly prompt an idle recipient unless a documented wake mechanism is independently verified.

## Orchestration extension (2026-09-22)

The approved design is in
`docs/superpowers/specs/2026-09-22-chauffeur-orchestration-design.md`.
Ordinary messages remain mailbox data. The explicit `chauffeur_follow_up`
operation is a separate permission to submit a new prompt through a verified
native composer. It uses a durable operation receipt and turn ID. Uncertain
terminal delivery is never blindly replayed.

`chauffeur_close_session` confirms the worker stopped and preserves bounded
captured history, with an accepted/replaced/abandoned outcome distinct from CLI
exit status. Replacement uses a fresh delegation with a predecessor ID, after
termination of the old worker. Workers run in provider-native YOLO mode at the
user's request. Model and effort overrides are launch-local; preset edits are
not required.

Parent attribution remains immutable. A separate controller identity permits an
explicit same-group recovery operation after a coordinator has ended. Recovery
cannot take workers from a live coordinator. Results route to the current
controller and are attributed to the actual worker and current turn.

## Inbox reminders through native hooks (2026-09-23)

Busy Claude Code and Codex sessions learn about new mail through native
lifecycle hooks: `UserPromptSubmit`, `PostToolUse` and `Stop`. The
`chauffeurctl inbox-hook` command asks the runtime to claim queued messages that
no hook has mentioned yet, and prints a fixed, metadata-only reminder: counts and
worker-result counts, never senders or bodies. A claim does not change the
message's delivery state; only `chauffeur_inbox` delivers.

- Hooks run only at lifecycle boundaries. They never type into the PTY, never
  start a turn, and do not wake an idle session. An idle recipient is still
  prompted by the user or through `chauffeur_follow_up`.
- `Stop` keeps a turn going at most once per native turn (Claude: once until the
  next prompt), and only when that call claimed new mail. Mail that arrives
  after that waits for the next prompt's `UserPromptSubmit` reminder.
- Delivery of a reminder is at-most-once. A crash after the claim commits, but
  before the provider reads the hook's output, loses that reminder, not the
  message. The inbox is the durable record.
- The same hooks report `/clear`, `/resume`, `/new` and `/fork`, so Chauffeur
  follows the active native conversation and Resume reopens it. Codex hooks are
  trusted per launch with a whole `hooks.state` map for Chauffeur's own
  session-flag hooks only; the user's own hooks keep their trust.

Evidence and design: `docs/chauffeur/plans/inbox-hooks.md`,
`Prototypes/codex_inbox_hooks_smoke.py` and
`Prototypes/cross_provider_inbox_smoke.py`.
