# Chauffeur orchestration skills and session control

Date: 2026-09-22
Status: Approved by the user; implementation and validation recorded in [orchestration validation](../../orchestration-validation.md).

## Intent and agreed scope

A coordinating agent running inside Chauffeur executes a larger saved plan by
breaking it into bounded assignments. Each assignment starts in a fresh, visible,
interactive Chauffeur session with its prompt supplied automatically. The user
can watch or intervene. Workers run sequentially in the same checkout, including
when the coordinator is using an existing worktree.

The coordinator reviews reported results and decides whether to accept the work,
continue the same session with corrections, or stop it and launch a fresh
replacement. Closing retains visible history. A fresh session resets conversation
context, not files or uncommitted changes in the checkout.

This adapts the Agent Team workflow to Chauffeur's existing MCP coordination
system. Existing messaging and delegation are partially implemented and require
end-to-end validation. Extend that system rather than create a second transport.

The user explicitly authorized enforcing YOLO mode for delegated workers.
Delegated launches and replacements therefore use the provider's native mode
that bypasses approval/permission prompts and, where that mode includes it,
sandbox restrictions. Apply this at launch without changing saved presets,
provider configuration files, or the coordinator's own execution policy.

Out of scope: an external control CLI, coordinators outside Chauffeur, a native
plan-execution engine, parallel worker scheduling, automatic branch integration,
recursive delegation, and model discovery through provider APIs. Existing
general-purpose delegation and messaging remain available.

## Existing foundations

- `ChauffeurCore/MCPTools.swift` defines discovery, messages, inbox/replies,
  delegation, status, and result reporting.
- `ChauffeurCore/Coordination.swift` and the runtime ledger track scoped callers,
  durable messages, delegation identities, retry keys, and parent/child ownership.
- `ChauffeurRuntimeKit/RuntimeCoordinator.swift` launches delegated sessions with
  an initial task. Delegation currently defaults to a new worktree; sharing a
  registered folder does not explicitly select the parent's existing worktree.
- `ChauffeurRuntimeKit/CLIAdapter.swift` starts interactive Codex and Claude CLIs
  and installs provider-specific coordination/status integration.
- Ordinary messages do not start turns. Result reporting leaves a worker alive.
- Runtime `closeSession` obeys the global `keepFinishedSessions` setting, whose
  default is false. Existing terminal captures can be evicted by storage limits.
- The bundled `chauffeur` skill and installer already support per-profile
  installation, updates, and removal.
- Presets persist tokenized launch arguments. The current editor parses and
  validates those arguments before saving, so malformed text cannot be saved.

## Components and responsibilities

1. **Skills:** task decomposition, role guidance, model choice, review decisions,
   handoffs, and saved plan/progress maintenance.
2. **MCP and ledger:** authenticated session operations, durable identities,
   ownership, retries, turn/result attribution, and recovery.
3. **Launch configuration and provider adapters:** argument editing, session
   overrides, enforced worker execution policy, and provider-specific turn input.
4. **Session lifecycle and history:** stop confirmation, closure outcome, retained
   captures, and UI visibility after completion.

The runtime manages processes and records. It does not decide whether code meets
the task's acceptance criteria. The coordinator owns that decision and final
verification.

## Skills and saved progress

### `chauffeur`

Extend the existing operational skill with launch options, follow-up submission,
result attribution, preserved-history closure, and recovery guidance. Keep peer
messaging and inbox instructions. Tool availability and runtime responses are
authoritative; guidance must not imply a queued message started another turn.

### `chauffeur-orchestrator`

Add a separate skill with bundled role references inspired by Agent Team:
worker, explorer, fixer, reviewer, specialist, and default. Roles provide prompt
instructions and suggested model/reasoning defaults, not a separate process type
or an enforced sandbox. The orchestrator may override every role suggestion.
The native Agent Team skill remains unchanged.

For each task the orchestrator supplies the outcome, project and checkout,
relevant context, owned components, constraints, acceptance criteria,
verification requirements, and expected handoff. Include the actual role
instructions in the prompt. Workers read applicable repository guidance and do
not delegate recursively.

The skill keeps progress in the user's existing plan file when suitable;
otherwise it creates `docs/chauffeur/plans/<plan-name>.md`. Record stable task IDs,
dependencies, acceptance criteria, current status, coordinator identity, checkout,
attempt and delegation/session IDs, selected preset/model/effort, reports,
verification evidence, and pending corrections. Record intent and retry keys
before requesting launches or replacement so recovery can reconcile with runtime
state instead of duplicating work. Do not automatically commit code or progress
files unless the user's task authorizes it.

Only one worker for this plan runs at a time. The coordinator does not make
competing edits while a worker owns an assignment. Independent review can use a
fresh reviewer session after the implementation worker closes, before advancing
the task. Reviewer no-edit instructions are behavioral guidance, not an OS
restriction, particularly under YOLO mode.

Updated installation decision (2026-09-22): publish both skills in one managed
Application Support catalog and automatically symlink them into `~/.agents/skills`
for Codex and each active team’s Claude home. Reconcile at startup, setup
completion, team saves, and status refresh. Preserve conflicting files; no copy
migration is needed. Settings presents health rather than install/remove actions.

## Session workflow and MCP contract

### Launch and discovery

Extend discovery with the current checkout/worktree identity, preset defaults,
curated model/effort suggestions, and provider capabilities. Suggestions are not
an account-specific availability guarantee.

Extend `chauffeur_delegate` with optional model and reasoning overrides and an
explicit registered checkout target. Existing callers retain their worktree
selection behavior; the orchestrator skill explicitly selects the shared current
checkout. Validate project membership and checkout identity rather than accept
an arbitrary path as authority. Carry forward explicitly authorized additional
repository access.

Return durable delegation, child, and initial turn identities. Persist the
resolved launch choices and enforced worker policy in the launch snapshot.
Report requested settings accurately; do not claim the provider confirmed a
model selection unless there is evidence from the provider.

### Reports, status, and follow-up

Retain discovery, inbox, replies, messages, and result reporting. Add turn
identity to reports and status so an old report cannot satisfy a new correction
turn. Legacy reports without a turn ID are accepted only for a delegation that
has never advanced beyond its initial turn; otherwise require an explicit ID.

Add `chauffeur_follow_up` for a parent to submit a correction prompt to its owned
worker. Inputs include delegation ID, expected current turn ID, prompt, and retry
key. A new accepted turn has a durable identity and retains the native
conversation, checkout, and launch settings. Changing model or effort requires
replacement in this version.

Ordinary messages remain mailbox data and never implicitly become terminal
input. Follow-up is a separate, explicit operation. Each provider adapter must
establish readiness and coordinate submission with the terminal input path so
the prompt is not inserted into busy execution, a user draft, or an input dialog.
A worker's result report alone does not prove that its CLI is ready for input.

Status distinguishes running, ready, needs attention, delivery uncertain,
reported result, and stopped execution. Return busy or unavailable conditions
without pretending to submit. Persist submission state before attempting input;
after a crash or timeout with ambiguous delivery, report uncertainty and do not
blindly replay. The coordinator may inspect, wait, or replace the session.

Current Codex status integration lacks reliable approval/input detection. YOLO
reduces approval interactions but does not prove readiness or eliminate login,
quota, trust, and other dialogs. Same-session follow-up must be demonstrated on
both supported providers. Unsupported versions report that capability as
unavailable and offer the replacement path; do not mark follow-up supported on
the strength of fixture tests alone.

### Close, accept, and replace

Add `chauffeur_close_session` for owned workers with delegation ID, outcome,
reason, retry key, and an explicit force option. Outcomes distinguish accepted,
replaced, and abandoned attempts. These are coordinator judgments, separate
from provider exit status. A reported result or successful process exit never
automatically marks work accepted.

Normal close captures history, stops the owned execution, confirms termination,
revokes its active coordination grant, and retains its records. A capture failure
is reported before normal closure destroys the live terminal. Explicit forced
closure may stop a stuck worker despite capture failure; retain the last valid
capture and disclose missing history. Capture any final output while the pane
still exists, without delaying forced termination indefinitely.

Replacement is a recoverable sequence of close and delegate, not a hidden
restart. Save the correction handoff, close the old attempt as replaced, confirm
it stopped, and launch a fresh attempt referencing its predecessor. If stopping
fails, do not launch a replacement into the shared checkout. If launching fails,
retain the prior history, filesystem changes, and pending task for retry. Never
reset or clean the checkout as part of replacement.

Stable retry keys return the same operation for identical content and reject
conflicting reuse. Follow-up, stop, replacement launch, and terminal input must
be serialized appropriately to prevent lifecycle races. Enforce a single active
attempt for a task when replacing; sequential scheduling across tasks belongs
to the orchestrator skill.

### Ownership and recovery

Control operations remain parent-owned and project/group-scoped. Peer messaging
keeps its existing group boundary. Workers cannot close arbitrary peers or
create children. Filesystem sharing does not grant MCP control authority.

After runtime restart, reconcile durable operations with actual processes and
never resend initial prompts automatically. An orchestrator resumed with its
session identity reconciles the saved plan with runtime records before acting.
For a new user-created coordinator replacing an ended coordinator, provide an
explicit same-group recovery operation that atomically adopts the ended
coordinator's workers. Reject adoption while the former coordinator is live;
knowing an ID or editing the plan file is not sufficient authority. Persist the
ownership change and retain original parent attribution for history.

## Models, reasoning, arguments, and worker execution policy

Add editable model and reasoning controls with provider-specific curated
suggestions. Both accept arbitrary typed values. Do not require provider model
discovery or treat the curated list as an allowlist.

In Create/Edit Agent Preset, including team-specific copies, the controls and
Launch arguments text stay synchronized:

- Recognized argument forms populate the controls, including custom values.
- Editing a control updates only the corresponding recognized options and
  preserves unrelated arguments. Selecting provider default removes that option.
- Conflicting or incomplete forms show a warning; do not silently choose one.
  An explicit picker edit resolves conflicting recognized occurrences for that
  field when the text can be parsed safely.
- Unparseable text remains intact and editable. Do not rewrite it using a stale
  parse; explain that picker synchronization resumes after syntax is repaired.
- Model, effort, argument syntax, and argument compatibility warnings never block
  saving. Unknown/custom values are preserved exactly.

Persist raw argument text in addition to derived argv so malformed input can
round-trip through save and reopen. Raw text is authoritative when present;
legacy records derive it from their existing argv. Do not launch stale derived
arguments when the latest raw text cannot be parsed. Separate editor diagnostics
from launch-time constraints; retain record identity and required metadata checks.

New Session exposes model/effort overrides initialized to Use preset. MCP and UI
use the same resolver. Explicit overrides replace matching preset options;
otherwise retain the preset/provider default. Store the resolved argv and choices
in the launch snapshot. Saved presets remain unchanged. Older requests without
the new fields retain their launch defaults.

At delegated launch, normalize recognized conflicting permission/sandbox options
and enforce the provider's YOLO equivalent after applying preset and session
choices. Show that execution policy in session details. Do not silently launch
with a different policy if the installed provider cannot support it; return a
specific launch failure. Native option forms and override precedence must be
verified against the installed CLIs during implementation.

Saving and launching are separate: arbitrary model/effort values may be passed
through, but a provider can reject them. Surface its failure without substituting
another model. Unparseable argv or conflicts with Chauffeur-owned launch routing
can prevent execution even though the preset was saved. Arguments remain argv
data and are never evaluated as shell code.

## Retained history and UI

Agent closure retains a visible ended session regardless of the global
keep-finished setting. Show outcome, task/attempt relationship, model/effort
selection, execution policy, and history access in existing session UI. Replaced
attempts remain distinguishable from their successors.

Mark retained captures as protected from automatic eviction until explicit
session deletion. Existing per-capture size and scrollback limits still apply:
this promises preservation of the captured history, not an unlimited transcript.
Protected capture bytes count toward reported storage use but are not deleted
to satisfy the automatic snapshot budget. If protected captures exceed that
budget, show storage usage accurately and continue eviction only for eligible
unprotected captures. Global retention changes cannot unprotect these records.

Persist protection before natural-exit cleanup can remove the worker, including
during launch and runtime recovery. A worker that exits before coordinator review
must remain reviewable. Explicit deletion releases the protection and removes the
record/capture through the existing deletion path. Preserve normal behavior for
unrelated sessions and maintain decoding compatibility for existing clients.

## Verification and acceptance

Use focused unit, integration, and native-provider checks:

1. Argument parsing/editing round trips, custom model/effort values, conflicting
   options, malformed saved text, warnings, legacy records, overrides, and YOLO
   normalization. Verify actual generated argv and unchanged saved presets.
2. MCP authentication, group isolation, ownership, adoption of ended parents,
   durable messaging, result/turn attribution, and idempotency conflicts.
3. Launch in the parent's actual checkout, including an existing worktree; fresh
   native conversation identity for each task and replacement.
4. Follow-up readiness, busy sessions, drafts/dialogs, stale reports, concurrent
   close/input, uncertain delivery, provider exit, and runtime restart.
5. Replacement stop confirmation, launch failure recovery, preserved filesystem
   changes, and no duplicate workers after timeout/retry.
6. Retention independent of global settings, natural exits, capture failure,
   forced closure, budget pressure, explicit deletion, and history after restart.
7. UI checks for synchronized editable suggestions, nonblocking save warnings,
   session overrides, policy display, and closed-history navigation; installer
   checks for both skills and their bundled references.
8. Real Codex and Claude runs exercising task launch, reporting, correction in
   the same conversation, acceptance/closure, and replacement with a different
   requested model where available. Verify both cross-provider directions using
   the existing messaging and delegation system as well as the new controls.
9. Recovery from a saved plan with runtime reconciliation and, when applicable,
   explicit coordinator adoption. Verify no duplicate launch or stale acceptance.

Document tested CLI versions and any unavailable model/account capabilities.
Fixture success is not evidence of native readiness or cross-provider delivery.
Use isolated fixture checkouts and the existing native validation conventions.
Implementation is complete only when the required native workflow works, or a
specific remaining compatibility limitation is explicitly accepted by the user.

## Delivery and review boundary

This is one coordinated feature: operational skills depend on the runtime
controls, and model selection shares launch resolution with the UI. Keep changes
focused on those boundaries; preserve unrelated local edits.

After approval of this written spec, use the writing-plans skill to produce a
reviewable implementation plan. Implementation starts after the user reviews
that plan and selects its execution method. No product code is changed by this
design document.
