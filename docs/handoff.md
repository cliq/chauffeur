# Next-session handoff

Updated: 2026-09-16. Baseline: `5a4b140` on `main`.

## Start here

The goal **implement `mvp-implementation-plan.md`** is complete within the user's
revised scope. The signed personal-use Release is ready for testing, the terminal
launcher is installed, and the complete manual is published. No acceptance run
or user permission request remains pending from that goal.

Read [implementation status](implementation-status.md) for the detailed evidence
and [V2 backlog](v2-plan.md) for deferred work. Continue with the user's new
feedback or requested scope. Do not restart completed acceptance runs or start
V2 merely because this is a new session.

## Release and installed launcher

- App: `build/Build/Products/Release/Chauffeur.app`.
- Certificate: **Developer ID Application: Leonardo Lobato**.
- App/runtime source in the build: through `f9a5cec`; subsequent commits update
  probes and documentation. Deep, strict signature verification passes.
- The final check relaunched this exact app path, restored the saved **Signos**
  project, and verified its current registered helper. Session, message, and
  preset records were preserved. The app was left open for the user to test.
  Recheck current activity before any future restart; do not reuse old PIDs.
- `/usr/local/bin/chauffeur` is installed, root-owned, mode 0755. It invokes
  this Release's `Contents/MacOS/chauffeur-launcher`. Help and a registered
  relative-folder invocation passed. Moving the app requires reinstalling the
  command from its new location.
- This is a local personal build, without notarization or an automatic updater.

Build only when code changes require it:

```sh
CHAUFFEUR_SIGN_IDENTITY='Developer ID Application: Leonardo Lobato' \
  Scripts/build-app.sh Release
open build/Build/Products/Release/Chauffeur.app
```

Use the same certificate for Debug builds when testing native service updates.
Run builds sequentially and leave app/runtime sources stable while they run.
Do not override build-product directories in a way that overwrites the Release.

## Last completed checks

All paths below are relative to this checkout. `.local/` and `.build/` are
ignored local evidence, not portable repository fixtures; terminal captures and
profile files must remain private.

| Check | Result and evidence |
| --- | --- |
| Swift tests | **71 tests in 18 suites pass**; `.build/unicode-swift-tests.log`. No app/runtime source changed after that run and the signed builds. |
| Native service and sleep/wake | **Pass**; `.local/live-service-native/summary.json`, `.build/live-service-active-windows.log`. Real Codex 0.154.0 and Claude Code 2.1.273 retain process, conversation, terminal identity, and launch context through normal UI quit, launchd crash, Settings restart, helper replacement, and sleep/wake. Both reply and recall their original word after recovery, including `café 界`. |
| Actual power cycle | macOS recorded sleep **2026-09-16 06:46:06 UTC**, wake **06:46:44 UTC**, followed by unlock and both provider replies. The user performed the cycle. This check is finished; another cycle is unnecessary for the old goal. |
| Fixture cleanup | The full service run unregistered its private job and removed temporary profiles/credentials. It verified the default service/store and Release remained unchanged. |
| Release startup | **Pass**; `.build/release-startup-artifacts/summary.json`, `.build/release-final-startup.log`. Visible cold launch, reopen after all windows close, normal Quit/cold relaunch, and native diagnostics Cancel/Save. |
| Real saved project | **Pass**; `.local/release-final/summary.json`, `.build/release-final-default-verification.log`. Fresh Release process, restored project, matching helper fingerprint, preserved records. |
| Administrator launcher installation | **Pass**; `.local/launcher-native/summary.json`. User authenticated the native installer; installed command opens the registered project. |
| Notifications | **Pass** for actual Notification Center delivery, cold click to the correct session/project, and helper recovery/update; `.local/notification-native-repeat/` and `.local/notification-native/`. |
| Other native/real-CLI checks | Presets/profiles, project/group editors, terminal input/clipboard/history, stop/quit, worktrees, repository access, and status evidence are indexed in [implementation status](implementation-status.md). |

Earlier failed service/sleep logs are diagnostic history. The passing full-run
summary above supersedes them. There is no live test process to resume from an
old tool session ID.

## Manual

- Published: [Chauffeur — App Manual](https://artifacts.cliq.dev/d/DPu8kdqJdE).
- Artifact Colab document ID: `DPu8kdqJdE`, version **1**, project **Chauffeur**,
  visibility **private**.
- Source: [manual.html](manual.html), 17 sections covering implemented features,
  workflows, keyboard shortcuts, recovery, and current limitations.
- Light/dark/mobile layouts and internal links were checked. The published HTML
  was fetched through MCP and matched the local source exactly.
- For future manual edits, update the local file and publish another version of
  this same document through Artifact Colab MCP; retain its private visibility
  unless the user asks to change access.

## User decisions to preserve

- Settings offers **System / Light / Dark**. Both appearances use the warm
  orange accent family; the user rejected blue and purple.
- Presets use the available Settings height. Project folder/discovery lists
  have bounded layouts, counts, and persistent scrollbars.
- Configuration folder pickers start at home with hidden folders visible.
- Launch arguments accept spaces/newlines and quoting. Smart dash/quote
  substitution is disabled, and Codex's `--yolo` alias is recognized.
- Worktrees appear under repositories in the sidebar. **New Worktree & Session**
  is also implemented, including recovery when checkout creation succeeds but
  agent launch fails.
- Closing tabs/windows or quitting the UI keeps agents running. Stop ends an
  execution; Resume Conversation uses its recorded native ID. Saved Chauffeur
  messages are coordination messages, distinct from native CLI chat history.

## Existing authorization and private data

- The user authorized cloning `~/.claudewho-*` and `~/.codexwho-*` for tests,
  then explicitly authorized copying only the matching Claude credentials into
  private clones. Originals must remain untouched; do not print or commit
  credentials. Some private clone notes still say permission is pending; that
  text predates the user's explicit approval.
- Authorized profile clones live under `.local/profile-isolation/`: A is the
  Personal label, B is the Cliq label, for each CLI. The two Claude profiles use
  the same account. Claude C's separate-account login stopped authenticating;
  the user said **continue with current profiles**, so a new login is not pending.
- The successful service run used private `claude-b` and its matching original
  `~/.claudewho-cliq` credential. Recheck authentication if a later test needs it;
  an old successful login does not guarantee credentials are still valid.
- The user authenticated the launcher installation and enabled notifications.
  Do not ask to repeat these completed setup steps without a new reason.
- The user chose to perform sleep/wake themselves. Do not put the Mac to sleep
  automatically. The required cycle has now passed.
- The default store at `~/Library/Application Support/Chauffeur` contains real
  project/session/preset data. **Never reset it for a fixture.** In particular,
  do not use `service_lifetime_smoke.py --use-default-service` against this store.
  Prefer unique private app IDs, LaunchAgent labels, sockets, and temporary data.

## Fixes and testing details worth retaining

1. **Release previously opened nothing.** On a case-insensitive filesystem,
   embedding `chauffeur` overwrote the GUI executable `Chauffeur`. The embedded
   launcher is now named `chauffeur-launcher`, with a build-time collision guard.
   Helpers are signed and replaced atomically; the outer bundle is resealed.
2. **Unicode under launchd.** A missing locale made tmux render non-ASCII text as
   underscores. `TmuxHost` now attaches with `-u`. Commit `f9a5cec` includes the
   regression; both native providers subsequently returned correct Unicode.
3. **Accessibility after wake.** An inactive app can expose no AX windows.
   The probe activates the existing PID and waits for its windows before
   resolving controls (`activateBeforeQuery` / `activateApplication`). This
   does not relaunch the app or agents. Fix: `9eb5bb8`.
4. **Native pointer checks.** Use actual Accessibility hit-testing to identify
   the owner at a click point. Notification Center can own a transparent
   full-screen window whose rectangle falsely suggests the app is covered.
5. **Service isolation.** Debug-only `CHAUFFEUR_SERVICE_PROBE_SOCKET` selects a
   private socket while preserving real `SMAppService` registration. The regular
   `CHAUFFEUR_SOCKET` fixture override bypasses registration and cannot establish
   native LaunchAgent acceptance.
6. **Desktop checks.** Recheck console lock and actual terminal state before
   interpreting a timeout. Avoid concurrent GUI-driving tests. Do not restart
   agent processes solely because a polling deadline expired.

Recorded environment: macOS 26.6.2, M5 Pro / 48 GB, Xcode 26.3, Swift 6.2.4,
tmux 3.6a, Codex 0.154.0, Claude Code 2.1.273. Recheck versions when relevant.

## Remaining boundaries and V2

The user explicitly moved these out of the completed goal:

- **Complete Codex ↔ Claude messaging/delegation:** Stage 3, F7, and the
  coordination portions of V3/V4. Partial MCP tools, durable mailboxes,
  delegation/UI, and skill installation exist; full cross-provider acceptance
  does not. Keep the integration labelled unverified.
- **Final workload testing:** ten real concurrent sessions, four Spaces,
  performance measurements, the complete F1–F7 workload, and three workdays.
  These were not run and must not be reported as passed.

Other documented limits: the different-account Claude check is user-deferred;
Codex approval/input detection is unavailable through the current integration;
real API-error hooks, transient notification banners, and alternate Focus
settings remain unverified. XCUITest did not run because macOS automation setup
blocked it; passing native tests used direct macOS Accessibility/keyboard input.
See [compatibility](compatibility.md) and [V5](decisions/V5-macos-lifetime.md).

No additional current-goal implementation is queued. Use the user's next test
feedback to select the next fix, or [the V2 plan](v2-plan.md) if they ask to begin
that phase.
