# V6 — Worktree navigation

Status: implemented on 2026-09-16 from the [worktree navigation plan](../worktree-navigation-plan.md).

## Decision

The project window is driven by the selected checkout, not by a strip of session
tabs. The sidebar has a segmented **Repositories / Sessions** control:

- **Repositories** shows each registered folder with a `Main checkout` row and its
  worktrees. Rows carry a live-session count and an orange attention badge; the
  repository row sums its rows. Selecting a checkout shows that checkout's sessions
  as cards above a single terminal, live first and finished ones behind a
  **Finished** disclosure. Selecting the repository row shows an overview of its
  checkouts. Every checkout offers **Launch Agent…** and **Open Shell**.
- **Sessions** keeps the previous flat list with the agent group picker and search
  field. Both filters act only on this list and never hide sessions in Repositories
  mode.

Tabs and the split terminal are removed, along with the ⌘D command. ⌘⇧] and ⌘⇧[
cycle within the selected checkout. ⌘⇧A cycles attention sessions across the
project and selects each one's checkout. Notification routes select the session
and its checkout without changing the sidebar mode.

## Registration is implicit

Every worktree Git reports for a folder is listed and usable. Launch Agent and
Open Shell register the Git worktree on demand through the existing idempotent
`registerWorktree` call, so records exist only for checkouts Chauffeur has used or
created. Reconciliation deletes a record whose checkout Git no longer lists when no
session refers to it; a record with session history stays as a **Finished** row. Git
entries whose directory is gone and that nothing refers to are hidden from the tree
and offered for `git worktree prune` in Manage Worktrees.

**Delete Worktree…** (`deleteWorktree`) removes the checkout with
`git worktree remove`, including external checkouts, when it is clean and has no
live sessions; then deletes the worktree records, the finished sessions that ran
there, their ledger rows (including messages and delegations they took part in) and
their saved terminal history. Manual Register and Unregister are gone from the UI.

## Persistence

`WindowState` gains `sidebarMode`, `selectedFolderID` and `selectedWorktreePath`.
`tabs` and `splitSessionID` are still decoded from older records and emptied on the
next write; a legacy record's selected session derives its checkout on restore. No
wire protocol bump: all new fields are optional.

## Shell sessions

`LaunchRequest.kind` (`agent` by default, `shell`) starts the user's login shell
(`$SHELL -l`, `/bin/zsh` fallback) in a checkout as a service-backed session. The
runtime synthesizes an `AgentPreset` of kind `shell` for the launch snapshot, skips
CLI capability probing, coordination, integration files, grant tokens, and preset
memory, and never counts the shell as a checkout occupant: agents launch beside a
shell without sharing consent, and shells launch beside agents. Shells cannot be
resumed and are hidden from `chauffeur_discover` peers. A live shell still blocks
worktree removal like any live session.

Accepted trade-off: no warning is shown when a shell and an agent edit the same
checkout.
