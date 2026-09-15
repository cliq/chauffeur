# Chauffeur — V2 backlog

Moved out of the current goal at the user's request on 2026-09-15. These items
remain planned work and do not block the current implementation goal. The
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
