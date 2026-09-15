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

Opening a changed development build refreshes its service registration
automatically. Use **Settings → Runtime → Restart Service** when the service is
unavailable. This unregisters the existing job, waits for
macOS to finish stopping it, registers the current bundle, and reconnects the UI.
Registration failures are shown with their original macOS error.

The runtime has its own tmux socket. Restarting it reconciles surviving session
processes; it does not replay tasks. Missing terminal ownership is recorded as
**Interrupted**. Reattach a live session, or use **Resume Conversation** for an
ended session with a recorded native conversation ID. See
[terminal history](terminal-history.md) for retained output and its limits.

Keep the app bundle at its registered path while its service is in use. Use
`CHAUFFEUR_SIGN_IDENTITY` with an existing certificate for persistent service
builds. The launch constraint requires that signing team and helper identifier.
Ad-hoc builds instead bind to the exact helper code hash and can encounter macOS
constraint failures when helper versions change. The build script generates the
constraint before signing the outer app. The app fingerprints both the plist and
helper, and refreshes registration for a changed build. This uses macOS's
[documented LaunchAgent constraint mechanism](https://developer.apple.com/videos/play/wwdc2023/10266/).

The embedding script signs temporary copies and atomically replaces helper files.
It avoids modifying executable files in place, which can conflict with the
kernel's cached signature; see Apple's [Updating Mac Software](https://developer.apple.com/documentation/security/updating-mac-software).
The build script then signs and verifies the completed app, including when only
an embedded helper changed and Xcode skipped signing the outer bundle.

## Inspecting health

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
They exclude command output, paths and configuration values. Structured log
files and a redacted diagnostics export remain separate implementation work.

## Service acceptance probe

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
