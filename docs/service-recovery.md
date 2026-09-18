# Background service setup and recovery

Open the built app to register its per-user LaunchAgent. Chauffeur starts its
runtime connection when the application launches, independently of window
restoration. The Welcome window opens and restores saved project windows.

If macOS requests approval, allow Chauffeur in **System Settings → General →
Login Items & Extensions**. The service health line links there. A registration
error remains visible while the app retries its connection.

The service reads the login-shell environment once at startup, with a ten-second
timeout. It preserves the resulting PATH order and appends missing Homebrew and
system executable directories. If the shell fails or times out, the service uses
its inherited environment plus those paths and shows an issue in the service
health line. Select full executable paths in presets if a CLI lives elsewhere.
Each session still receives its own filtered environment and selected profile.

## Restarting

Opening a changed or moved app refreshes its service registration automatically,
including moving the same build from its build folder to `/Applications`.
Registration is recorded only after the runtime reports the expected executable
path, executable hash, Debug/Release build, and data directory. A mismatched
runtime triggers one registration refresh per app launch; a persistent mismatch
stays disconnected with an explicit error. **Settings → Runtime** shows the
verified runtime path. **Start Service** also refreshes an enabled but stale job.

Debug uses `Chauffeur Debug.app`, a separate `.debug` bundle identifier, the
`dev.chauffeur.debug.runtime` job, and `~/Library/Application Support/Chauffeur Debug`.
Release retains `Chauffeur.app`, `dev.chauffeur.runtime`, and the existing
`~/Library/Application Support/Chauffeur` store. Their preferences, notifications,
logs, URL schemes, and terminal commands are independent. An explicit
`CHAUFFEUR_SOCKET` override remains a custom connection and is not marked verified.

Use **Settings → Runtime → Restart Service** when the service is
unavailable or still running an older build. This refreshes the current bundle's
registration, then explicitly replaces the registered job's process with
`launchctl kickstart -k` before reconnecting the UI. Refreshing registration alone
can leave the previous process alive. The job label comes from the bundled
LaunchAgent plist, so Debug, Release, and private test services stay separate.
Registration and process-restart failures are shown with their original error.

`Prototypes/service_installation_smoke.py` checks relocation of an unchanged signed
app, reuse of the runtime on an unchanged relaunch, process replacement on repeated
explicit restarts, distinct build metadata, and
rejection of a Release runtime by the Debug app. It uses a unique service label
and empty temporary stores. Evidence is under `.local/service-installation-artifacts/`.

The runtime reconciles its legacy tmux socket and the sockets owned by
Chauffeur Sessions helpers. Restarting it reconciles surviving session
processes; it does not replay tasks. Missing terminal ownership is recorded as
**Interrupted**. Reattach a live session, or use **Resume Conversation** for an
ended session with a recorded native conversation ID. See
[terminal history](terminal-history.md) for retained output and its limits.

New packaged-runtime sessions use an independent signed **Chauffeur Sessions**
owner. It stays alive through UI quit and runtime restart/stop, preserving the
original AppData consent lifetime. Updating Chauffeur keeps old owners and their
signed cached apps available until their sessions drain. An owner crash leaves
its terminals alive; the next new session gets a fresh owner/server. Existing
pre-helper sessions keep their old attribution and are not migrated or killed.
See [privacy prompts](privacy-prompts.md) for consent limits and recovery.

Owner manifests live in `runtime/session-owners/`, and immutable signed helper
copies in `session-apps/`, under the data root. Do not remove these while sessions
are alive. A missing or invalid packaged helper prevents new launches, with an
error asking for reinstallation; it does not fall back to starting a server from
the runtime. Reinstalling the app preserves the separate cache and live owners.

`Prototypes/real_repository_access.py` verifies this with the signed Release
runtime and real Codex 0.154.0 (integration enabled) / Claude Code 2.1.273
(basic-terminal mode) sessions.
After their first file-reading turn, it kills only the private runtime and
starts a replacement against the same store. Both retain their process ID,
terminal identity, conversation ID, profile and launch snapshot. Their next
turn recalls the previously read values and writes the expected files in the
primary worktree and selected additional repository. No task is replayed.
Evidence is under `.local/repository-access-{codex,claude}/`. This verifies
standalone runtime-crash recovery; actual LaunchAgent updates and sleep/wake
have separate acceptance requirements.

### Resuming after a checkout changes

Resume uses the original configuration directory, working directory, additional
directories, and recorded native conversation ID. It verifies the checkout at
each path before altering the ended session or terminal. If a folder is missing,
restore the original checkout to the recorded path. If a different folder or Git
repository replaced it, restore the original to resume, or start a new session
in the replacement. Relinking the project affects new launches and worktree
inventory; it does not rewrite previous launch snapshots.

The check covers plain folders as well as Git checkouts. Saved directory and Git
identities remain stable when the original folder is moved away and back on the
same filesystem. A copy or new clone does not prove it is the original checkout.
For older sessions, a complete list of recorded Git identities can verify every
path; missing or incomplete identity records produce an explicit error and
require a new session. Saved history remains available after a rejected resume.
See [worktree recovery](worktrees.md#moving-the-main-repository).

### Stopping a session during startup

**Stop Session** also cancels an in-progress launch or resume. It terminates a
pending CLI inspection, waits for terminal-creation cleanup, revokes the session
credential, and records the stopped attempt as **Interrupted**. A retry of the
same launch request returns that record. Starting again requires an explicit
new session or a supported native conversation resume.

Resume is unavailable while Stop is in progress. A stop request for the old execution does
not carry over to a later resumed process. Failed terminal handoffs remove their
temporary launch payload and terminal before releasing the launch reservation.
Stopping an already-running process still uses graceful termination, with the
existing Force Stop action available if it does not exit.

### Stop all sessions and quit

Choose **Chauffeur → Stop All Sessions and Quit…** to review the active executions
across every project. One confirmation lists the targets. **Cancel** leaves them
running. Confirmation sends graceful stops to the listed targets, then quits the
UI only after they have stopped. A session started after the confirmation opened
is outside that target list.

If an execution refuses to stop, Chauffeur stays open and reports that it is still
stopping. Open its **Session Details**, choose **Force Stop…**, review that
confirmation, and retry Stop All or use normal Quit. The background service stays
available after the UI quits. Stop All is also available with all project windows
closed; normal **Quit Chauffeur** continues to leave agents running.

`Prototypes/session_controls_smoke.py` verifies these controls through macOS
Accessibility in an isolated signed Debug app. It reproduced the missing menu
item and duplicate confirmation sheets before their fixes. The check covers
individual Stop/Force Stop cancellation and confirmation, one Stop All dialog
across two windows, fixed confirmation targets, an agent ignoring graceful stop,
and successful Stop All after every project window closes. It also checks
immutable launch details after a shared preset edit, sidebar search, new-session
and open-project commands, and cycling all three attention items. Invalid
executables produce failed records without processes. Evidence:
`.build/session-controls-artifacts/`.

A separate read-only check of the existing real exited Claude session verifies
the displayed preset/revision, configuration/working paths, and expanded launch
snapshot against its stored record. The record and prior window visibility are
unchanged afterward. Private evidence: `.local/session-details-native/`.

Terminal inventory and saved-screen metadata use printable separators so they
work with a minimal login environment and the C locale. Unreadable inventory
produces a service error; it is not interpreted as proof that all agents exited.

After moving the app, open it at the new location to refresh its service. Use
`Configuration/LocalSigning.xcconfig` to select a development team and an existing
certificate for persistent service builds. The launch constraint requires that
signing team and helper identifier.
Ad-hoc builds instead bind to the exact helper code hash and can encounter macOS
constraint failures when helper versions change. The embedding script generates the
constraint before signing the outer app. The app fingerprints both the plist and
helper plus its canonical location, and refreshes registration for a changed or
moved build. This uses macOS's
[documented LaunchAgent constraint mechanism](https://developer.apple.com/videos/play/wwdc2023/10266/).

The embedding script signs temporary copies and atomically replaces helper files.
It avoids modifying executable files in place, which can conflict with the
kernel's cached signature; see Apple's [Updating Mac Software](https://developer.apple.com/documentation/security/updating-mac-software).
The Makefile then signs and verifies the completed app, including when only
an embedded helper changed and Xcode skipped signing the outer bundle.

## Inspecting health

App-wide errors have one native dialog owner. An error appears once even with
several project windows and Welcome open. Repeats of the currently displayed
error coalesce; distinct errors wait until the current dialog is dismissed.
Reporting the same error again after dismissal still presents it. A native
regression routes two unregistered fixture folders while two project windows
are open. It reproduced three dialogs for one error before the fix, and now
verifies one dialog, ordered errors, and unchanged live sessions. Evidence:
`.build/app-errors-before-fix.log` and `.build/app-errors-session-controls.log`.

```sh
.build/debug/chauffeurctl status
launchctl print gui/$(id -u)/dev.chauffeur.runtime
```

The first command reports the runtime version, identity, live count and MCP
endpoint. The second reports whether launchd has the job and whether it is
running. The socket lives at
`~/Library/Application Support/Chauffeur/runtime/runtime.sock`.

Startup failures before socket availability also write an error code to the
macOS system log under subsystem `dev.chauffeur.runtime`, category `startup`.
They exclude command output, paths and configuration values. See
[diagnostics](diagnostics.md) for structured logs and the redacted export.

## Startup cancellation regression checks

`LaunchCancellationTests` runs fixture executables and a private tmux server.
It pauses CLI version inspection, tmux creation, and terminal handoff, then stops both a new
launch and a resume. It checks probe termination, credential revocation, removal
of terminal/payload files, request retry identity, later explicit resume, normal
exit classification, and saved-screen capture without locale variables. It also
checks handoff timeout cleanup and rejects malformed terminal inventory.
No provider account or real conversation is involved.

The same runtime changes pass `Prototypes/runtime_smoke.py` and
`Prototypes/worktree_smoke.py`, covering regular launches, terminal reattachment,
service restart, retained history, and launch/removal reservations.

## Service acceptance probe

### Private native service fixture

`Prototypes/native_live_service_smoke.py --registration-only` passes using a
separately signed Debug app with a unique bundled LaunchAgent label and private
data directory. It exercises actual `SMAppService` registration, normal UI quit,
launchd recovery after killing only that helper, the native Runtime settings
restart button, and automatic registration refresh after replacing the bundled
Release helper with the Debug helper. Cleanup unregisters only its private job.
The existing default runtime and saved records remain unchanged. Evidence:
`.local/live-service-registration/summary.json`.

The full command without `--registration-only` additionally prepares real Codex
and Claude sessions, selects their configuration folders through the native
picker, and checks process/conversation continuity and provider replies after
each recovery. Both Codex 0.154.0 and Claude Code 2.1.273 now pass those
live-session recovery steps, including recall of their original check word and
Unicode replies. The run's initial and updated snapshots retain the same
processes, conversations, terminal identities, and launch snapshots. The complete
`--sleep-wake` run also passes, including native replies after wake, private-job
cleanup, and unchanged default service, saved records, and Release bundle.
Evidence: `.local/live-service-native/summary.json`.
The harness refuses a locked console and changes no OS permission or lock setting.

The Debug-only `CHAUFFEUR_SERVICE_PROBE_SOCKET` chooses the private IPC socket
without bypassing service registration. The fixture's plist supplies its unique
job label and `--data-dir`; Release does not use this override. Temporary profile
copies and the authorized matching Claude credential stay private and are
removed afterward, including any new path-specific Keychain entry. This also
avoids coupling the lifecycle test to Documents-folder consent for each unique
test app. An earlier attempt with the Documents-based clones timed out in a
Codex filesystem operation while macOS checked that fixture's file access.

For a user-performed sleep cycle, run the full fixture with `--sleep-wake`.
After both agents reply following helper replacement, it prints
`READY_FOR_SLEEP` and waits for the user to sleep, wake, and unlock the Mac.
`Prototypes/system_sleep_observer.swift` records actual macOS `willSleep` and
`didWake` notifications; it neither requests sleep nor changes power settings.
After wake, the fixture checks the same agent processes, terminal identities,
launch snapshots, and conversations, then asks both providers to recall their
original check word. The private power-event log and final report are written
under `.local/live-service-native/`. The passing run recorded sleep at
06:46:06 UTC and wake at 06:46:44 UTC on 2026-09-16. Both agents then recalled
their original check word and returned `café 界` through the native terminal,
retaining their process and conversation identities. The probe activates the
existing app and waits for its Accessibility windows before resolving controls;
this handles macOS exposing no windows for an inactive app immediately after wake.
It does not relaunch the app or agents as part of wake recovery.

### Original empty-store probe

With a Debug build signed using the same certificate as your Release build and
an **empty default store**, run:

```sh
python3 Prototypes/service_lifetime_smoke.py --use-default-service
```

This registers the real Chauffeur LaunchAgent, checks UI quit/relaunch, launchd
recovery and the app's service restart, then unregisters the test job. It retains
the empty data directory. It refuses a store with projects or presets, and an
existing job unless `--replace-test-registration` explicitly selects an earlier
empty test registration. Reports are private under
`.build/service-lifetime-artifacts/`. This probe uses no provider accounts and
does not establish session continuity, Spaces, sleep/wake or OS UI automation.
