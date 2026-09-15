# V4 — groups and delivery

Status: ledger isolation fixtures passed; cross-provider delegation gate open.

## Decision

Use a runtime-owned SQLite ledger with WAL and FULL synchronization. Accept messages only after transaction commit. Persist scoped sessions, hashed grants, mailbox records and delegation reservations. Resolve project/group membership from the bearer token, not tool arguments or MCP transport IDs. The UI's Unix-socket API is separately protected by filesystem permissions and peer UID checks.

Message states distinguish queued, received by inbox integration, acknowledged, failed and cancelled. A repeated stable retry key returns the existing record; different content using the same key fails. Exited recipients keep their inbox. Only the actual recipient can acknowledge or reply as recipient. Messages never flow to PTY input.

Delegation reserves a durable child identity before launching, shares the normal launch path, defaults to a new worktree, limits live children to four by default, and rejects recursive delegation. A reported result does not stop the child's terminal or stop counting its live process. Failed operations preserve the delegation and any created worktree.

## Evidence

`LedgerTests` checks two groups in one project and another project sharing a group UUID, guessed message IDs, foreign recipients, revocation, no default authorization, restart visibility, idempotency conflicts, recipient-only acknowledgement, reservation limits, depth limits and result attribution. `runtime_smoke.py` checks real HTTP requests, UI-independent runtime restart, duplicate launch request IDs, and persisted inbox state using fixture CLIs.

## Remaining gate evidence

Real Codex→Claude and Claude→Codex delegation while the UI is closed remains open. More integration cases are needed for crash windows during worktree creation/delegation, native approval prompts, long-running busy recipients, and parent termination. Result-message acceptance and delegation result updates share one transaction. Pruned completed messages retain retry tombstones so old retries cannot create new deliveries. The user will explicitly prompt an idle recipient unless a documented wake mechanism is independently verified.
