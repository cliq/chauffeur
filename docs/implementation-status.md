# MVP implementation status

This tracks the original [implementation plan](mvp-implementation-plan.md).
Unchecked requirements remain in scope. Fixture evidence does not substitute for
the PRD's real-CLI, native-window, and daily-use acceptance scenarios.

## Current executable evidence

- Swift package: core records, validation, file store, runtime kit, runtime binary,
  helper, and tests.
- Tests: canonical paths/discovery, per-child environment, argument validation,
  atomic file replacement/conflicts/corrupt files, durable group-scoped messages,
  grant revocation, retry keys, bounded single-level delegation, and safe Git
  worktree creation/removal.
- `Prototypes/terminal_continuity.py`: detached output, native tmux redraw,
  Unicode, unsent input and resize with the same process.
- `Prototypes/runtime_smoke.py`: actual socket and HTTP service, three fixture
  sessions, shared-preset credentials, group probes, retry identity, runtime
  kill/restart with surviving tmux processes, mailbox persistence and revocation.

## Stage audit

| Plan items | Current state | Still required |
| --- | --- | --- |
| Stage 0 V1–V5 | Five decision documents; V1–V4 fixture implementations | Real CLI/profile gates; Codex daemon resolution; SwiftTerm view and macOS/Spaces/LaunchAgent gate |
| 1.1 Records/store | Implemented and tested, including external reload/conflict errors | Complete reference-integrity checks; automatic file watcher independent of subscribers; empty-set UI acceptance |
| 1.2 Runtime skeleton | Lock, peer-checked Unix socket, version handshake, health helper, background executable | LaunchAgent registration, structured redacted log files, native service health UI |
| 1.3–1.7 Presets/projects/groups/welcome/windows | Core records and runtime mutations implemented | Native UI, discovery cancellation UI, relink/archive workflows, four-window acceptance |
| 1.8 Basic launch | Runtime launch, fixture CLI, filtered environment, private exec handoff, terminal attachment/input/resize/stop | SwiftTerm view, real CLI account/status checks, complete preflight, Codex backend ownership |
| 1.9 Session details | Launch snapshot exposed through runtime API | Native details UI |
| 2.1 Screen/history | tmux maintains live screen/history; capture API exists | Persisted bounded history/snapshots, disk budgets/cleanup; native attach/search/copy/link verification |
| 2.2 Reconnect | Positive pane/process reconciliation; explicit native-ID resume path | Real-provider resume and service-failure edge cases |
| 2.3–2.4 Quit/tabs/split | Runtime lifetime independent of connections | Native UI, keyboard controls, restoration and quit actions |
| 2.5 Worktrees | Create/list/safe-remove implementation and Git integration test | UI, external inventory reconciliation/registration; launch/removal concurrency audit |
| 2.6 Multiple repos | Explicit additional folder selection in launch API; primary main checkout excluded | Real CLI access test, shared-checkout warning UI |
| 2.7 Status/attention | Lifecycle records, authenticated event handler, unread/pending counts | Real hooks, attention UI, notifications and closed-UI routing |
| 2.8 Sleep/service loss | Runtime reconciliation loop | Native sleep/wake and recovery UI |
| 3.1–3.3 Credentials/MCP/mailboxes | Implemented with ledger and HTTP fixture checks | Full HTTP/client compliance, real shared-preset connections, UI cancellation/delivery details |
| 3.4 Delegation | Durable reservation, launch path, worktree default, limits, depth check, result transaction | Bidirectional real-CLI acceptance, crash-window integration tests and failed-child visibility audit |
| 3.5 Wake | Bounded inbox wait; no terminal message injection | Pending-attention UI and real idle/busy validation |
| 3.6–3.7 Coordination UI/skill | Tool descriptions exist | Session message/delegation UI, bundled skill, loading/install/removal routes |
| 4.1–4.5 Packaging/compatibility/retention/diagnostics/docs | Package builds; compatibility and gate notes started | Signed app, registration, settings UI, bounded snapshot cleanup, diagnostics export, setup/recovery guide |
| 4.6 Release checklist | Not run | Ten real sessions/four Spaces, timings/hardware record, all F1–F7 scenarios, three normal workdays and failure log |

## Next implementation order

1. Finish foundation edge-case tests and resolve Codex backend token/stop ownership.
2. Build the XcodeGen app with native project windows, preset/project management,
   SwiftTerm attachment, session creation/details, tabs and split.
3. Complete native service lifecycle, persisted screen/history, worktree UI and
   reconciliation, attention/messages/delegation UI and skill integration.
4. Package/sign the app; run the complete real-CLI and daily-use acceptance audit.

The goal remains active until every required item and release gate is proved.
