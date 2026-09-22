---
name: chauffeur-orchestrator
description: Execute an implementation plan through sequential, visible Chauffeur worker sessions. Use when a coordinator should decompose saved work, launch role-guided workers in the current checkout, review results, request corrections or replacements, and maintain durable progress.
metadata:
  version: "1.0.0"
---

# Chauffeur orchestrator

Use Chauffeur's operational skill and MCP tools to run one worker at a time for
a saved plan. This workflow extends Chauffeur coordination; it does not invoke
or modify the native Agent Team skill. Delegated workers are interactive and
visible to the user. They share filesystem state only when you explicitly select
the current registered checkout.

## Prepare durable progress

Use the user's existing plan when it can hold execution state. Otherwise create
`docs/chauffeur/plans/<plan-name>.md`. Do not commit code or the progress file
unless the user's task authorizes commits.

For each stable task ID, record dependencies, acceptance criteria, status,
coordinator identity, checkout, attempt and delegation/session/turn IDs,
selected preset/model/effort, reports, verification evidence, and pending
corrections. Record launch or replacement intent and its retry key before making
the request. On resume, reconcile the file with runtime discovery and status;
never infer that missing local context means an operation failed or launch a
duplicate worker.

## Assign a worker

Choose one role and read only its reference. Model and reasoning entries are
suggestions, freely overridable for the task and provider. Confirm advertised
capabilities, pass explicit choices when desired, and report resolved launch
settings accurately. A prompt cannot prove the provider selected them.

| Role | Use | Reference |
| --- | --- | --- |
| Default | General implementation or analysis | [default](references/roles/default.md) |
| Worker | Substantial implementation with clear ownership | [worker](references/roles/worker.md) |
| Explorer | Focused investigation without edits | [explorer](references/roles/explorer.md) |
| Fixer | Small, understood fixes | [fixer](references/roles/fixer.md) |
| Reviewer | Independent review without edits | [reviewer](references/roles/reviewer.md) |
| Specialist | Difficult debugging, architecture, or escalation | [specialist](references/roles/specialist.md) |

Build a self-contained prompt containing the outcome, project and registered
checkout, relevant context, owned components, constraints, acceptance criteria,
verification requirements, and expected handoff. Include the selected role's
instruction block inline; a role name or file path does not load it. Tell every
worker to read applicable repository guidance and not delegate recursively.
Include this completion protocol in every assignment: when finished or blocked,
call `chauffeur_discover`, then `chauffeur_report_result` with its `delegationID`,
`currentTurnID` as `turnID`, a stable retry key, and the result/verification/blocker
summary. End the worker turn after reporting; the coordinator decides closure.
Delegated execution uses Chauffeur's enforced worker policy; do not describe a
role as a sandbox or claim its no-edit guidance is technically enforced.

## Wait for completion

While a worker is active, keep the coordinator turn active using
`chauffeur_inbox` with bounded waits (`waitSeconds: 25`). Read and acknowledge
messages after recording their result. Do not finish the coordinator turn just
because the inbox is temporarily empty: queued messages do not wake an idle CLI.
Use delegation status to reconcile a missing report, failed process, or uncertain
operation. A worker's attributed report is the completion notification; terminal
silence and process exit are not acceptance criteria.

## Review and advance

Do not make competing edits while a worker owns the assignment. Match reports
to the active delegation and turn. Inspect the changed files and verification,
then accept, request a same-session correction only when readiness is established,
or close as replaced and launch a fresh attempt after confirmed termination.
When status is uncertain, stop and reconcile rather than replaying input.

After meaningful implementation, you may close the implementation attempt and
launch a fresh reviewer before advancing. Reviewer no-edit instructions remain
behavioral under the delegated execution policy. Keep attempts and retained
history linked in the plan. Complete the user's final verification after all
tasks satisfy their acceptance criteria.
