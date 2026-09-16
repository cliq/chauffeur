# Chauffeur — V2 backlog

Messaging/delegation and final workload testing moved out of the current goal
at the user's request on 2026-09-15. Worktree UX and agent-memory investigation
items were added on 2026-09-16. These items remain planned work and do not block
the current implementation goal. The
[implementation plan](mvp-implementation-plan.md) retains the detailed requirements;
[implementation status](implementation-status.md) tracks current-scope work.

## Complete Codex ↔ Claude messaging/delegation

References: Stage 3.1–3.7, PRD F7, and the coordination portions of V3/V4.

Existing work includes authenticated, group-scoped MCP tools and durable mailboxes;
per-provider messaging fixtures; delegation reservations and result storage;
message/delegation UI; and the bundled coordination skill with profile-specific
installation controls. That evidence does not establish complete cross-provider
coordination.

Remaining V2 work:

- Complete both directions of real Codex ↔ Claude messaging and delegation,
  including all seven MCP tools and delegation while the UI is closed.
- Finish HTTP/client compliance and controlled preservation of existing MCP
  servers in selected profiles.
- Verify retry/crash behavior, failed-child visibility, group boundaries, and
  child launch, status, and result reporting.
- Verify busy/idle recipient behavior and bounded inbox waits.
- Complete native coordination UI/skill interaction and real model use of the
  guidance, then run the complete F7 acceptance scenarios.

## Final workload testing

References: Stage 4.6 and the full PRD §9 release workload.

Remaining V2 work:

- Run at least ten concurrent real CLI sessions across the four defining
  projects, with windows on four Spaces and shared/separate presets.
- Record hardware, macOS and CLI versions, session-switching latency, and
  reconnection timing against the proposed targets.
- Run the complete F1–F7 end-to-end workload, including cross-provider
  delegation, attention, UI quit/reopen, and recovery under load.
- Use the app for three normal workdays; record and resolve workload failures.

Focused tests of features and fixes still belong to the current goal. Deferring
this final workload does not mark its performance or daily-use targets as passed.

## Searchable Git ref picker

Linear: [CLI-69](https://linear.app/cliqdev/issue/CLI-69/v2-add-a-searchable-git-ref-picker-for-worktree-base-refs) · `v2` · Backlog.

Build a reusable branch/ref picker for the **Base ref** field in **New Worktree
& Session**, suitable for reuse in other worktree creation forms.

- Search and select local branches, remote-tracking branches, and tags from the
  selected repository, with each kind clearly identified.
- Accept directly entered commit SHAs, tags, and symbolic refs such as `HEAD`.
- Resolve the input to a commit before creation and explain invalid or
  unavailable refs without losing the user's input.
- Refresh choices when the repository changes; show loading and error states.

## Configurable worktree branch naming

Linear: [CLI-70](https://linear.app/cliqdev/issue/CLI-70/v2-support-configurable-default-branch-naming-patterns-for-worktrees) · `v2` · Backlog.

Support default branch naming patterns such as `feature/*`, `username/*`, and
`feature/mbl-9999-slug`. This extends the current-feedback request to derive a
plain sanitized branch name from the session title.

- Define templates for a prefix, username, sanitized title slug, and optional
  issue identifier. Document supported placeholders with concrete examples.
- Preview the resulting branch name and validate it using Git's branch rules.
- Preserve manual overrides and integrate with live title-derived suggestions.
- Decide configuration scope, precedence, and missing-value behavior before
  implementation, including whether Team, project, or repository overrides are
  needed beyond an app default.
- An issue identifier is an input to the template; automatic Linear integration
  is not implied by this item.

## Agent memory across worktrees

Linear: [CLI-71](https://linear.app/cliqdev/issue/CLI-71/v2-investigate-codex-and-claude-code-memory-continuity-across-git) · `v2` · Backlog.

Investigate whether Codex and Claude Code treat a session in a linked worktree
as a new project, and which learnings from the main checkout are available.
Memory continuity is currently an open question, not a verified capability.

- Distinguish repository instructions (`AGENTS.md` / `CLAUDE.md`), user/profile
  instructions, persistent or automatic memory, conversation history, and
  session resume behavior.
- Compare main-checkout and linked-worktree sessions using the same profile;
  separately identify the effect of choosing a different configuration profile.
- Determine how each provider identifies a project or memory scope: working
  directory, repository identity, configuration directory, or another key.
- Check tracked instruction files separately from ignored or untracked local
  files that may be absent from a new worktree.
- Use controlled fixtures to test main checkout → worktree and worktree → main
  checkout visibility. Record CLI versions, configuration, official sources,
  reproduction steps, and results.
- Produce a provider comparison and recommend Chauffeur behavior and user
  documentation. Any implementation needed to share memory is follow-up work;
  this investigation does not authorize copying private memory across profiles.
