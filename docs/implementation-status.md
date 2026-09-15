# MVP implementation status

This tracks the original [implementation plan](mvp-implementation-plan.md).
Unchecked requirements remain in scope. Fixture evidence does not substitute for
the PRD's real-CLI, native-window, and daily-use acceptance scenarios.

## Current executable evidence

- Swift package: core records, validation, file store, runtime kit, runtime binary,
  helper, and tests.
- Debug and Release native apps build with embedded signed runtime/helper, SwiftTerm views,
  project/preset/group editors, session launch/details, worktrees, tabs and split.
- A Debug app probe exercises four windows and ten rendered fixture terminals,
  Unicode input, resize, reattach, close/reopen and normal/forced UI termination.
  XCUITest is blocked before execution by macOS Automation Mode authentication.
  Full native acceptance remains open; see V5 for current evidence.
- A focused C regression proves PTY children reset inherited blocked signals and
  ignored handlers before exec; it failed before the signal-inheritance fix.
- Versioned terminal captures persist normal history and active screens, enforce
  line/byte budgets, and survive terminal/runtime loss. Native history is
  read-only and searchable; completed-message cleanup preserves queued/received
  messages. See [retention and recovery](terminal-history.md).
- Twenty-eight Swift tests: canonical paths/discovery, per-child environment, argument validation,
  atomic file replacement/conflicts/corrupt files, durable group-scoped messages,
  grant revocation, retry keys, bounded single-level delegation, and safe Git
  worktree creation/removal.
- Bundled coordination skill with explicit per-profile install/update/remove
  controls, ownership/conflict checks, private files, and stale-review rejection.
  Native Codex and Claude metadata fixtures prove profile-specific discovery and
  removal. Delegated children discover their own IDs and can report results.
  See [coordination skill](coordination-skill.md).
- Periodic Git inventory reconciliation follows known worktree moves and branch
  changes, preserves base commits and launch paths, and distinguishes replacement
  checkouts. Launch/removal reservations cover pending sessions, additional
  directories, aliases, and Git identities after moves. The real-Git/socket
  fixture reproduces the former removal race and checks the fix; see
  [worktrees and cleanup](worktrees.md).
- Typed diagnostics export through Settings and `chauffeurctl`, with explicit
  live/cached/unavailable observations. Private structured logs rotate within
  2 MiB. Tests cover sensitive-field exclusion, hostile input, bounds, legacy
  records, private exports, rotation, and unsafe-file preservation. See
  [diagnostics and runtime logs](diagnostics.md).
- `Prototypes/terminal_continuity.py`: detached output, native tmux redraw,
  Unicode, unsent input and resize with the same process.
- `Prototypes/runtime_smoke.py`: actual socket and HTTP service, three fixture
  sessions, shared-preset credentials, group probes, retry identity, runtime
  kill/restart with surviving tmux processes, mailbox persistence and revocation.
  Worktree API checks cover preview/create/remove and external registration,
  preserving external checkout files on unregister.
- `Prototypes/real_codex_integration.py`: two private authenticated Codex profiles,
  three real sessions, six attributed messages with native approval, completion
  IDs, scoped peer stop, explicit resume and runtime/MCP reconnection.
- `Prototypes/service_lifetime_smoke.py`: actual bundled LaunchAgent registration,
  normal UI quit/relaunch, launchd recovery and app-driven service restart, using
  an empty default store and cleaning up its registration. Relative executable
  names and missing login-shell environments are covered by the runtime fixture.
  Developer ID builds use a stable team/helper launch constraint; the Release
  helper starts and a subsequent Debug build refreshes registration for its own
  helper. Both bundles verify after embedding and signing.

## Stage audit

| Plan items | Current state | Still required |
| --- | --- | --- |
| Stage 0 V1–V5 | Decision documents; fixtures; real default-route Codex credential/stop evidence; actual LaunchAgent lifecycle | Full real CLI/profile gates; remaining macOS/Spaces gate |
| 1.1 Records/store | Implemented and tested, including external reload/conflict errors | Complete reference-integrity checks; targeted file watcher (current one-second reload also runs with no UI); empty-set UI acceptance |
| 1.2 Runtime skeleton | Lock, peer-checked Unix socket, version handshake, health helper, verified bundled LaunchAgent registration/recovery; bounded structured logs with typed redaction | Remaining live-service release acceptance |
| 1.3–1.7 Presets/projects/groups/welcome/windows | Native editors, cancellable discovery, relink/archive, welcome and project windows implemented | Full interaction and four-Spaces acceptance |
| 1.8 Basic launch | Runtime/real Codex launch, filtered environment, private exec handoff, terminal input/resize/stop | Full native account/status checks, Claude launch, complete preflight |
| 1.9 Session details | Native details show the immutable launch snapshot and lifecycle/coordination records | Real-session interaction acceptance |
| 2.1 Screen/history | tmux live state; bounded persisted snapshots, disk cleanup, native history/search | Real CLI native attach/search/copy/link verification and sustained rotation |
| 2.2 Reconnect | Positive pane/process reconciliation; real Codex explicit native-ID resume and MCP reconnect | Claude resume and remaining service-failure edge cases |
| 2.3–2.4 Quit/tabs/split | Native tabs/split, window-state writes, quit/stop-all and keyboard commands implemented | OS keyboard and real-CLI/Spaces acceptance; direct normal/force-quit fixture implemented |
| 2.5 Worktrees | Create/list/safe-remove; periodic external inventory; identity-based moves/replacements; pending launch/removal and metadata-write reservations; Git/socket regression fixture | Real-CLI removal and native control acceptance; whole-repository relocation; recovery/resume after external checkout replacement |
| 2.6 Multiple repos | Explicit additional folder selection in launch API; primary main checkout excluded | Real CLI access test (shared-checkout warning and explicit additional-folder UI implemented) |
| 2.7 Status/attention | Lifecycle records, real Codex completion IDs, unread/pending counts | Claude hooks; native attention signals; notifications and closed-UI routing |
| 2.8 Sleep/service loss | Runtime loop plus native wake reconnect, health/recovery actions; actual service termination/restart verified | Real sleep/wake and service lifecycle with live real sessions |
| 3.1–3.3 Credentials/MCP/mailboxes | Ledger/HTTP fixtures; real Codex shared-profile credentials and messages | Full HTTP/client compliance; Claude shared-profile connections; remaining real tool cases |
| 3.4 Delegation | Durable reservation, launch path, worktree default, limits, depth check, result transaction | Bidirectional real-CLI acceptance, crash-window integration tests and failed-child visibility audit |
| 3.5 Wake | Bounded inbox wait; no terminal message injection | Real idle/busy validation (pending-attention UI implemented) |
| 3.6–3.7 Coordination UI/skill | Tool descriptions, message/delegation details, bundled skill, explicit install/update/remove controls; native metadata discovery/isolation/removal fixture | Native control interaction and real model use of guidance; full F7 acceptance |
| 4.1–4.5 Packaging/compatibility/retention/diagnostics/docs | Developer ID local builds; actual registration/update; retention settings/cleanup; diagnostics export; terminal, diagnostics and service recovery guides | Full release acceptance; native save-dialog interaction; remaining recovery guide |
| 4.6 Release checklist | Not run | Ten real sessions/four Spaces, timings/hardware record, all F1–F7 scenarios, three normal workdays and failure log |

## Next implementation order

1. Complete Claude authenticated checks, cross-provider MCP cases, and remaining
   foundation edge-case tests.
2. Stabilize and verify native terminal/window lifetime, restore/focus, and the
   app interaction scenarios through direct probes and XCUITest.
3. Complete native service lifecycle, persisted screen/history, worktree UI and
   reconciliation, attention/messages/delegation UI and skill integration.
4. Package/sign the app; run the complete real-CLI and daily-use acceptance audit.

The goal remains active until every required item and release gate is proved.
