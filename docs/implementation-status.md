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
- Sixty-nine Swift tests: canonical paths/discovery, folder routing/launcher installation and relocation repair, per-child environment, argument validation and quoting,
  atomic file replacement/conflicts/corrupt files, durable group-scoped messages,
  grant revocation, retry keys, bounded single-level delegation, and safe Git
  worktree creation/removal.
- [Startup cancellation](service-recovery.md#stopping-a-session-during-startup)
  now cancels CLI inspection and terminal creation, waits for cleanup, and
  excludes concurrent resume until Stop finishes. Deterministic fixtures cover
  both launch and resume cancellation, pending tmux creation, later successful resume, no stale Stop
  classification, and terminal/payload cleanup after handoff timeout. They
  reproduced the former pending-launch bug before the fix. Printable tmux
  metadata delimiters fix inventory and history capture with a minimal/C-locale
  environment; malformed output is reported instead of treated as no sessions.
  Runtime and worktree socket regression fixtures pass with these changes.
- Native fixture windows verify the full-height Presets layout, warm orange
  accents in light/dark appearance, and project folder lists with persistent
  scrollbars, counts, and bounded heights. Repository worktrees appear in the
  sidebar. The preset editor accepts space/newline-separated arguments with
  quoting, preserves literal hyphens, and recognizes Codex's `--yolo` alias.
  A native directory panel check confirms home as its initial location with
  hidden folders visible. Visual evidence is under `.local/ui-preview/` and
  `.local/settings-preview/`; these previews use an isolated socket and app ID.
- [New Worktree & Session](worktrees.md#create-a-worktree-and-start-an-agent)
  creates a checkout and launches from one sidebar flow, with a scrollable sheet
  and fixed actions. Durable creation retry IDs avoid duplicate checkouts across
  concurrent requests and runtime restarts. A direct native Debug fixture checks
  invalid-branch recovery, retained checkout after agent failure, a fresh launch
  reusing it, literal initial-task forwarding, and session selection. Evidence:
  `.build/quick-session-artifacts/`. Included in the current signed Release.
- Worktree-manager controls pass through actual macOS Accessibility actions and
  targeted keyboard input in an isolated signed Debug app. Checks cover creation,
  current destination preview, disabled controls while Git works, confirmation
  cancellation, external unregister, and safe managed removal. Concurrent
  registration now coalesces to one record; the regression reproduced twelve
  records before the fix. Evidence: `.build/worktree-controls-artifacts/`.
  These changes are in the current Release; XCUITest remains unrun.
- Native terminal keyboard and clipboard controls pass through macOS with two
  fixture sessions: Unicode/literal input, Control-B/Escape/Control-C, selection
  and copy, bracketed paste, Command-F history search, read-only history, session
  switching/split shortcuts, and Command-Q/relaunch preserving process/input.
  Terminals now expose distinct focusable live/history accessibility elements
  with displayed text and selection. Evidence: `.build/terminal-controls-artifacts/`.
  These changes are in the current Release; link/mouse and retention evidence follows below.
- Real Codex 0.154.0 and Claude Code 2.1.273 basic-terminal runs now pass native
  trust prompts, Unicode typing, clipboard, window/PTY resize, and history search
  in the signed Debug app. Normal and forced UI quit preserve each real CLI's
  process, launch profile and unsent draft; a second provider reply succeeds after
  reattachment. Searches use generated reply text absent from the prompts.
  Blank terminal cells exposed as NUL characters are now mapped to spaces, with
  a native cursor-gap regression. Evidence: `.local/terminal-native-{codex,claude}/`.
- Native Command-click opens ordinary and OSC 8 labeled links through the actual
  OS URL handler. The OSC 8 check reproduced tmux dropping link targets until its
  attachment advertised hyperlink support. Native drag selection/copy, Shift
  selection while the CLI tracks the mouse, and press/release/drag/wheel events
  pass through the signed Debug app and tmux. Evidence:
  `.build/terminal-pointer-artifacts/`. A separate 60,000-line fixture verifies
  sustained Unicode/ANSI history rotation, six periodic detached captures,
  encoded byte limits, stable capture deduplication, same-process runtime
  recovery and history after tmux loss. These are focused terminal checks;
  final workload/performance tests remain in V2. The link fix is in the current Release.
- [Metadata integrity and preset defaults](metadata-and-presets.md): child
  ownership checks, path-bearing reference diagnostics, archived history
  preservation, service-owned preset revision increments, and a remembered
  successful user preset per project. Core tests cover external edits and stale
  writers; native fixture checks cover last-used selection, empty-set launch
  prevention, and unchanged running snapshots after preset edits. Runtime and
  worktree socket regressions pass.
- Metadata watching now uses macOS file events with cached records and directory
  listings. Idle observations do no metadata I/O; tests prove one-file reloads,
  corruption repair, directory replacement, dropped-event rescan, and root-watch
  recovery. The runtime observes external metadata edits with no UI attached
  while preserving the live agent's process. Saves and launch preflight retain
  immediate disk/version checks. See [filesystem notifications](metadata-and-presets.md#filesystem-notifications).
- Native preset/project/group editor checks pass with three projects across two
  sets, native file panels, invalid-path/argument validation, Git discovery,
  relinking, duplicate prevention, archive/reopen, cancellation, empty-set launch
  prevention, and stale-save rejection. Creating a project now closes Welcome
  after its sheet dismisses and the project window becomes visible; the native
  check reproduced the extra window before the fix. Evidence:
  `.build/editor-controls-artifacts/`. Session/window and terminal-pointer
  regressions pass. The handoff fix is included in the current Release.
- Native profile selection passes with two concurrent project windows for each
  current CLI in the signed Release app. Native account displays and process
  configuration paths match the authorized A/B clones; inherited fake provider
  credentials are absent. Codex clones have distinct stored account contexts;
  Claude A/B still share an account, with its different-account check deferred
  by the user. Both basic-mode sessions report Activity unknown. No model prompts
  are sent. Evidence: `.local/profiles-native-{codex,claude}/` and
  `Prototypes/native_profile_selection.py`.
- [Appearance settings](appearance.md) offer System, Light, and Dark with saved
  app-wide selection. Four isolated native app launches verify persistence,
  window/terminal default colors, cursor contrast, newly created terminals, and
  preservation of existing text in terminal and history buffers.
- [Session and quit controls](service-recovery.md#stop-all-sessions-and-quit)
  pass through native OS actions across two project windows. Stop/Force Stop
  cancellation and confirmation, one Stop All dialog with fixed targets,
  resistant-process recovery, and Stop All with every project window closed
  pass. The check fixed a missing menu item and duplicate sheets. Command-K now
  reveals a hidden sidebar, and Next Attention cycles all items instead of
  alternating between the first two. New-session/open-project shortcuts,
  immutable preset details after edits, and missing-executable failure without
  process creation pass. A real exited session's details and expanded launch
  snapshot also match its stored metadata. Evidence:
  `.build/session-controls-artifacts/` and `.local/session-details-native/`.
  Normal Command-Q/terminal controls still pass; these fixes are in the current Release.
- [Terminal folder routing](terminal-launcher.md) passes native cold/warm launch,
  folder selection, shared-project choice, repeated-route and service-loss layout
  recovery checks. Startup subscriptions wait for helper registration refresh;
  writes that could not connect retain their queued window state.
- Release startup now verifies an actual visible GUI window in an isolated copy.
  Fixed a case-insensitive filename collision where embedding `chauffeur`
  overwrote `Chauffeur`; the embedded launcher is now `chauffeur-launcher`, with
  a build-time collision guard. Both Debug and Release have verified signatures
  from Leonardo Lobato's Developer ID certificate. The Release startup capture
  shows the Welcome screen connected to its isolated runtime without an alert.
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
- Repository identities now survive same-filesystem moves of the main repository.
  Real-Git/runtime tests verify relinking, legacy record migration without duplicate
  registration, runtime reopen, and clean removal. Resume validates each original
  primary/additional checkout before altering the ended terminal. Fixture tests
  cover Git replacement, plain-folder replacement, changed symlinks, missing paths,
  and restoration with the same conversation/profile. Complete legacy Git identity
  lists remain usable; incomplete legacy records are reported explicitly.
  See [checkout recovery](service-recovery.md#resuming-after-a-checkout-changes).
- Real Codex 0.154.0 and Claude Code 2.1.273 sessions pass main-repository
  relocation, primary/additional checkout-replacement refusal, restored-checkout
  resume with conversation recall, live-removal refusal, and clean removal with
  branch preservation. Claude's installed update is tested in basic-terminal mode;
  its coordination/status hooks remain outside the verified version list.
  Explicit Codex read-only arguments with additional folders now produce an
  actionable preflight error, matching the native CLI's observed restriction.
  The signed Debug build, runtime/worktree socket fixtures, and native quick-session
  probe pass. These recovery changes are in the current Release.
- Real Codex 0.154.0 and Claude Code 2.1.273 basic-terminal sessions read and
  write a primary worktree and an explicitly selected additional repository,
  including paths with spaces. Random file contents are absent from prompts;
  actual file changes establish tool access. The main checkout and a sibling
  worktree remain unchanged. Killing and restarting the private signed Release
  runtime preserves each real CLI process, conversation, profile and launch
  snapshot; another tool-using turn succeeds afterward. Evidence:
  `.local/repository-access-{codex,claude}/` and
  `Prototypes/real_repository_access.py`. This is standalone crash recovery,
  separate from native LaunchAgent updates and OS sleep/wake.
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
  Native **Send Test Notification**, enabled-helper update/recovery, actual
  Notification Center delivery and clicking its alert with the UI quit pass.
  The previously closed project opens with the correct session selected, without
  changing session/message records or restarting the runtime. Tests use existing
  read sessions; no data reset or OS preference changes. Evidence is private under
  `.local/notification-native/`. Transient banners and alternate Focus settings
  remain unverified. Notification and terminal-folder routes dismiss Welcome
  after opening their project, with native regression coverage. These changes
  are in the current Release.

## Current Release — 2026-09-16

`build/Build/Products/Release/Chauffeur.app` now includes app/runtime changes
through `7062126`, signed with Leonardo Lobato's Developer ID certificate. Deep,
strict bundle-signature verification passes. The embedded `chauffeur-launcher`
and GUI `Chauffeur` are distinct files.

`Prototypes/release_startup_smoke.py --native-controls` verifies an actual visible
cold launch, reopening with every window closed, normal Quit/cold relaunch with
the fixture runtime surviving, and native diagnostics export cancellation/save.
The OS save dialog writes a valid live report with private permissions. These
checks use an isolated signed copy and macOS Accessibility/keyboard input;
XCUITest remains unrun. Evidence: `.build/release-startup-artifacts/`.

The user's Release was then relaunched at its original path and opened the saved
Signos project. The service reconnects, and the existing session, message and
preset records match the pre-launch snapshot. Private evidence:
`.local/release-editor/`. The current Release is open for testing. Build and
startup logs are `.build/release-editor-build.log` and
`.build/release-editor-startup.log`.

## Current-goal stage audit

| Plan items | Current state | Still required |
| --- | --- | --- |
| Stage 0 V1–V5 | Decision documents; native CLI terminal continuity, bounded history and two-window profile/account displays; real scoped-stop evidence; actual LaunchAgent lifecycle | Remaining status and focused macOS checks; distinct-Claude-account check deferred by user; coordination and final Spaces workload are in V2 |
| 1.1 Records/store | Atomic writes, reference/ownership diagnostics, external-edit conflicts, preset revision tracking, last-used preference, empty-set UI/runtime checks, and targeted filesystem watching with recovery pass | — |
| 1.2 Runtime skeleton | Lock, peer-checked Unix socket, version handshake, health helper, verified bundled LaunchAgent registration/recovery; bounded structured logs with typed redaction | Remaining live-service release acceptance |
| 1.3–1.7 Presets/projects/groups/welcome/windows | Native preset/project/group editors, file panels, validation, discovery, relink/archive/reopen, cancellation, stale-save rejection and Welcome handoff pass; OS-driven window/search/new-session/attention commands pass | Final four-Spaces workload is in V2 |
| 1.8 Basic launch | Real Codex/Claude launch and two-window profile/account displays; filtered child environments, preflight failures, native input/resize/stop and immutable launch details; cancellable launch/resume with terminal cleanup | Distinct-Claude-account check deferred by user; remaining semantic attention acceptance tracked under 2.7 |
| 1.9 Session details | Native immutable context after preset edits, individual execution controls, and a real saved session's expanded launch snapshot match the stored record | — |
| 2.1 Screen/history | tmux live state; bounded persisted snapshots, disk cleanup, native history/search; real Codex/Claude native attach, Unicode, clipboard and reply search; native link/mouse forwarding and 60,000-line retention/recovery pass | — |
| 2.2 Reconnect | Positive pane/process reconciliation; real Codex/Claude explicit native-ID resume and MCP reconnect | Remaining service-failure edge cases and full native acceptance |
| 2.3–2.4 Quit/tabs/split | Native tabs/split, window-state writes and OS keyboard commands pass; real Codex/Claude normal/forced UI quit preserve process and draft; native Stop All confirmation/cancellation, fixed targets, resistant-stop recovery and no-window operation pass | Final Spaces workload is in V2 |
| 2.5 Worktrees | Create/list/safe-remove; periodic external inventory; identity-based moves/replacements; pending launch/removal and metadata-write reservations; legacy migration fixtures and real Codex/Claude repository-relocation, replacement/resume, and removal checks; native manager controls and concurrent registration pass | — |
| 2.6 Multiple repos | Explicit additional-folder UI and shared-checkout warning; real Codex/Claude read/write at primary worktree and selected additional path, with spaces; main checkout and sibling worktree remain unchanged | — |
| 2.7 Status/attention | Lifecycle records, real Codex/Claude completion IDs, permission attention hooks, unread/pending counts; optional durable notifications; actual Notification Center delivery/cold click and enabled-helper recovery/update pass | Remaining native attention signals; transient banners/alternate Focus settings unverified |
| 2.8 Sleep/service loss | Runtime loop plus native wake reconnect, health/recovery actions; actual service termination/restart; real Codex/Claude survive standalone Release runtime crash with same process/conversation and successful tool use afterward | Real sleep/wake and native LaunchAgent lifecycle with live real sessions |
| 2.9 Appearance setting | Implemented; System/Light/Dark, persistence, native window and terminal default-color checks pass | — |
| 2.10 Terminal project launcher | Implemented Settings installer and folder routing; native cold/warm and Release startup checks pass; relocation repair and literal argument forwarding tested | Actual `/usr/local/bin/` installation requires macOS administrator authentication |
| 2.11 Quick session on a new worktree | Implemented; concurrent/persisted retry tests and native sheet/fixture-agent launch pass | Real CLI/native acceptance remains tracked under 1.8 and 2.5 |
| 4.1–4.5 Packaging/compatibility/retention/diagnostics/docs | Developer ID local builds; actual registration/update; retention settings/cleanup; diagnostics export; terminal, diagnostics and service recovery guides | Remaining focused recovery acceptance and recovery guide |
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
