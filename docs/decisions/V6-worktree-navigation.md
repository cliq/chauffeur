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
