# MVP implementation status

This tracks the [implementation plan and current goal scope](mvp-implementation-plan.md#current-goal-scope).
On 2026-09-15, the user moved completion of Codex ↔ Claude messaging/delegation
and final workload testing to [V2](v2-plan.md). They do not block the current goal.
Other unfinished requirements remain in scope. Fixture evidence does not establish
unverified real-CLI or native behavior; deferred workload checks remain unverified.

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
- Thirty-five Swift tests: canonical paths/discovery, per-child environment, argument validation and quoting,
  atomic file replacement/conflicts/corrupt files, durable group-scoped messages,
  grant revocation, retry keys, bounded single-level delegation, and safe Git
  worktree creation/removal.
- Native fixture windows verify the full-height Presets layout, warm orange
  accents in light/dark appearance, and project folder lists with persistent
  scrollbars, counts, and bounded heights. Repository worktrees appear in the
  sidebar. The preset editor accepts space/newline-separated arguments with
  quoting, preserves literal hyphens, and recognizes Codex's `--yolo` alias.
  A native directory panel check confirms home as its initial location with
  hidden folders visible. Visual evidence is under `.local/ui-preview/` and
  `.local/settings-preview/`; these previews use an isolated socket and app ID.
- [Appearance settings](appearance.md) offer System, Light, and Dark with saved
  app-wide selection. Four isolated native app launches verify persistence,
  window/terminal default colors, cursor contrast, newly created terminals, and
  preservation of existing text in terminal and history buffers.
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
- `Prototypes/real_claude_integration.py`: three real Claude sessions across two
  private profiles, native account screens and live configuration indicators,
  inherited provider credentials absent, six attributed messages, permission
  attention/completion hooks, scoped peer stop, explicit resume and runtime/MCP
  reconnection. Both supplied profiles report the same account/organization;
  distinct-Claude-account selection remains unverified.
- `Prototypes/service_lifetime_smoke.py`: actual bundled LaunchAgent registration,
  normal UI quit/relaunch, launchd recovery and app-driven service restart, using
  an empty default store and cleaning up its registration. Relative executable
  names and missing login-shell environments are covered by the runtime fixture.
  Developer ID builds use a stable team/helper launch constraint; the Release
  helper starts and a subsequent Debug build refreshes registration for its own
  helper. Both bundles verify after embedding and signing.

- Optional [session notifications](notifications.md) with a durable, coalesced outbox,
  signed accessory app, opt-in controls, and strict project/session navigation.
  Launch Services warm/cold URL routing and helper startup with the UI closed
  pass; the user enabled notifications and the native helper reports authorized.
  Delivery/click acceptance remains open.

## Current-goal stage audit

| Plan items | Current state | Still required |
| --- | --- | --- |
| Stage 0 V1–V5 | Decision documents; fixtures; real default-route Codex credential/stop evidence; actual LaunchAgent lifecycle | Remaining profile, terminal, status, and focused macOS checks; coordination and final Spaces workload are in V2 |
| 1.1 Records/store | Implemented and tested, including external reload/conflict errors | Complete reference-integrity checks; targeted file watcher (current one-second reload also runs with no UI); empty-set UI acceptance |
| 1.2 Runtime skeleton | Lock, peer-checked Unix socket, version handshake, health helper, verified bundled LaunchAgent registration/recovery; bounded structured logs with typed redaction | Remaining live-service release acceptance |
| 1.3–1.7 Presets/projects/groups/welcome/windows | Native editors, cancellable discovery, relink/archive, welcome and project windows implemented | Remaining editor/window interaction checks; final four-Spaces workload is in V2 |
| 1.8 Basic launch | Real Codex/Claude launch, filtered environment, private exec handoff, terminal input/resize/stop; Claude native account/process configuration checks | Full native account/status checks, distinct-Claude-account check, complete preflight |
| 1.9 Session details | Native details show the immutable launch snapshot and lifecycle/coordination records | Real-session interaction acceptance |
| 2.1 Screen/history | tmux live state; bounded persisted snapshots, disk cleanup, native history/search | Real CLI native attach/search/copy/link verification and sustained rotation |
| 2.2 Reconnect | Positive pane/process reconciliation; real Codex/Claude explicit native-ID resume and MCP reconnect | Remaining service-failure edge cases and full native acceptance |
| 2.3–2.4 Quit/tabs/split | Native tabs/split, window-state writes, quit/stop-all and keyboard commands implemented | OS keyboard and focused real-CLI acceptance; direct normal/force-quit fixture implemented; final Spaces workload is in V2 |
| 2.5 Worktrees | Create/list/safe-remove; periodic external inventory; identity-based moves/replacements; pending launch/removal and metadata-write reservations; Git/socket regression fixture | Real-CLI removal and native control acceptance; whole-repository relocation; recovery/resume after external checkout replacement |
| 2.6 Multiple repos | Explicit additional folder selection in launch API; primary main checkout excluded | Real CLI access test (shared-checkout warning and explicit additional-folder UI implemented) |
| 2.7 Status/attention | Lifecycle records, real Codex/Claude completion IDs, permission attention hooks, unread/pending counts; optional durable notifications; native warm/cold URL routing and background helper startup; user enabled and authorized notifications | Actual OS delivery/click, enabled-helper recovery/update, and remaining native attention signals |
| 2.8 Sleep/service loss | Runtime loop plus native wake reconnect, health/recovery actions; actual service termination/restart verified | Real sleep/wake and service lifecycle with live real sessions |
| 2.9 Appearance setting | Implemented; System/Light/Dark, persistence, native window and terminal default-color checks pass | — |
| 2.10 Terminal project launcher | Todo — requested by user | Install a launcher in `/usr/local/bin/`; open the project containing the selected folder |
| 2.11 Quick session on a new worktree | Todo — requested by user | One flow from a repository in the sidebar to a new worktree and session |
| 4.1–4.5 Packaging/compatibility/retention/diagnostics/docs | Developer ID local builds; actual registration/update; retention settings/cleanup; diagnostics export; terminal, diagnostics and service recovery guides | Focused packaging/recovery acceptance; native save-dialog interaction; remaining recovery guide |
| 4.7 Complete app manual | Todo — requested by user, after app work | Document every feature and its usage; publish through Artifact Colab MCP |

## V2 — outside the current goal

| Deferred item | Plan references | Status |
| --- | --- | --- |
| Complete Codex ↔ Claude messaging/delegation | Stage 3.1–3.7, F7, coordination portions of V3/V4 | Partially implemented; remaining completion and acceptance moved to [V2](v2-plan.md) |
| Final workload testing | Stage 4.6, full PRD §9 workload | Not run; ten real sessions, four Spaces, performance measurements, complete F1–F7 sweep, and three workdays moved to [V2](v2-plan.md#final-workload-testing) |

## Next implementation order

1. Complete remaining core app features, account-selection checks within the
   user's current profile constraints, and foundation fixes.
2. Stabilize and verify native terminal/window lifetime, restore/focus, and the
   focused app interaction scenarios through direct probes and XCUITest.
3. Complete native service lifecycle, persisted screen/history, worktree UI and
   reconciliation, and session attention/notifications.
4. Package/sign the app, finish focused verification, and publish the complete
   app manual through Artifact Colab, including current V2 limitations.

The goal remains active until all current-scope work is complete and its required
checks pass. V2 items are excluded from that completion decision.
