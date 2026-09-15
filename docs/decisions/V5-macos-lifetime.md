# V5 — macOS lifetime

Status: native app and fixture lifetime implemented; full macOS acceptance open.

## Implementation

XcodeGen builds a macOS 15+ SwiftUI/AppKit app with `WindowGroup(for: UUID.self)`,
a single welcome window, and SwiftTerm terminal views. It embeds locally signed
runtime/helper binaries and a `SMAppService.agent(plistName:)` LaunchAgent.
The native service-health UI offers registration, restart and Login Items settings.

Project windows persist their frame, tabs, selected group/session, sidebar state,
and split session through runtime-owned JSON writes. Layout writes retain their
original file version so external edits cause an explicit conflict. Closing a tab
or window detaches its terminal views. Normal quit flushes queued layout changes
before termination and keeps project windows marked for reopening.

## Actual LaunchAgent evidence

`Prototypes/service_lifetime_smoke.py --use-default-service` passes against the
Debug bundle and an empty default store on the recorded development Mac. It
uses the actual `SMAppService` registration and default runtime socket. Normal
application startup shows a window and connects; quitting the UI leaves the same
runtime available. Terminating the registered helper with the UI closed causes
launchd to start a new runtime on the recorded MCP endpoint. Reopening the UI
reconnects to that runtime; the app's unregister/register restart path also
starts a new one. Cleanup unregisters the test service. Private reports are in
`.build/service-lifetime-artifacts/`.

The Release app also starts its own bundled helper, confirmed using the running
process's executable path, and leaves that helper available when the UI process
exits. The service check then opens a Debug build signed with the same Developer
ID certificate and verifies that launchd selects its helper. The builds have
different executable fingerprints, exercising automatic registration refresh.
Release evidence is under `.build/service-release-artifacts/`.

This exposed and corrected several startup issues:

- A previously unseen service can return `.notFound`; registration now handles
  that as well as `.notRegistered`, and retains registration errors in the UI.
- Runtime connection startup belongs to the application delegate, independent
  of SwiftUI window restoration. The Welcome scene explicitly presents at launch.
- launchd can pass a relative `BundleProgram` as `argv[0]`. The runtime resolves
  its loaded executable before locating the sibling `chauffeurctl`.
- Ad-hoc helper updates encountered launch-constraint failures. Certificate
  builds bind the job to their signing team and helper identifier, using the
  [documented SpawnConstraint mechanism](https://developer.apple.com/videos/play/wwdc2023/10266/).
  Ad-hoc fixtures bind to the helper code hash. The app fingerprints both the
  plist and executable and refreshes registration for an updated build.
  Helpers are signed in a staging directory and atomically replaced, avoiding
  in-place executable updates and their cached-signature problems. The final
  build step seals and verifies the outer app even for a helper-only rebuild.
- The login shell times out under launchd on this Mac. Startup now appends
  missing Homebrew/system search paths and records an issue when it must use
  the inherited environment. The runtime fixture also exercises this fallback.

The service probe contains no CLI sessions and does not prove the remaining
Spaces, sleep/wake, notification or real-session gates. See
[service recovery](../service-recovery.md) for setup and development updates.

## Native fixture evidence

`Scripts/build-app.sh` and `Scripts/build-app.sh Release` succeed.
`codesign --verify --deep --strict` validates the local app and its embedded
binaries. Release app/helpers are Developer ID signed with hardened runtime and
timestamps; the app has not been notarized or published. The default script also
supports ad-hoc signing for isolated fixtures. Xcode disables hardened runtime
for the ad-hoc Debug app; the Release app retains it.

`Prototypes/native_window_smoke.py` passes against the actual Debug app with an
isolated runtime with four projects and ten fake CLI sessions. Its Debug-only
in-app probe exercises all ten SwiftTerm views, Unicode input, resize and
reattachment with unsent input. History search finds normal-buffer output and the
active screen; typing in the history view does not reach the live terminal.
It also opens an existing project twice, closes
and reopens a project window, and checks normal quit plus forced UI termination
across three app launches. The Python harness compares runtime/process identities
and saved window state. Reports are under `.build/native-probe-artifacts/`.

The history presentation owns one terminal controller until dismissal. Frame
saves use throttled main-queue updates, including while sheets are active, and
initial visible geometry is saved even before a move or resize. The probe
checks saved geometry against the actual window across all three launches.

A concurrent first-history request exposed a race: a caller could receive
“no saved history” while another capture was still running. Requests now share
the in-flight capture task. The runtime fixture reproduces the failure with
eight simultaneous requests before the fix and verifies that all receive history
afterward. Native probe failures now also report history loading status and
capture byte counts.

The probe drives native view methods directly. Its cached-view images can show
terminal pixels but do not reliably capture every layer of a SwiftUI window.
They do not establish OS keyboard, accessibility, notification, or Spaces behavior.

## OS automation attempt

The Xcode `ChauffeurAppUITests` target builds. Its runner requires hardened
runtime disabled for the locally signed UI-test bundle. The Release app retains
hardened runtime. The test runner then times out before test execution while enabling
macOS Automation Mode. `automationmodetool` reports that user authentication is
required; `DevToolsSecurity -status` reports Developer mode disabled. These system
settings were left unchanged, and the user was asked to enable UI-testing access.
The user has said they will enable access. The latest check still reports both
Automation Mode and Developer mode disabled; XCUITest has not yet run.

General macOS Accessibility access is enabled for the development session. The
separate `Prototypes/worktree_controls_smoke.py` harness uses it to type into the
actual manager and press its buttons and confirmation dialogs in an isolated
signed Debug app. `app_accessibility_probe.swift` checks the target text field's
focus and sends keyboard events only to that fixture PID. It makes no permission
changes. Creation, current destination preview, disabled fields/actions during
Git work, confirmation cancellation, external unregister, dirty-removal refusal,
and clean removal preserving the branch pass. Reports and window captures are
in `.build/worktree-controls-artifacts/`. This establishes those native worktree
interactions; it does not establish the remaining terminal or notification checks.

## Notification implementation and partial evidence

The signed app now includes an accessory notification app, a durable opt-in
outbox, Settings controls, and project/session URL routing. See
[session notifications](../notifications.md) for behavior and architecture.

The native fixture sends a URL through Launch Services to reopen a closed project
window and select the recorded session without duplicates. A separate cold launch
starts the app with all saved project windows closed and no tabs, then opens only
the addressed project/session. All ten fixture agent PIDs remain unchanged.

The actual service probe launches the bundled notification app with Chauffeur's
UI closed. It reads native authorization (`notDetermined`) over the private IPC
connection and exits while notifications are disabled, without requesting access.
This proves the helper can run and communicate. The user subsequently enabled
notifications, and the helper reports `authorized`, enabled, and connected.
Actual notification delivery and click handling still require native acceptance.

## Remaining gate evidence

- Run remaining native terminal keyboard/copy/paste/find/link and accessibility
  interactions. XCUITest still requires the previously requested system access.
- Validate sleep/wake, remaining service-loss cases,
  banner delivery/clicks with the UI closed, and enabled-helper recovery/update.
- Repeat lifetime scenarios with both real CLIs and their intended accounts.

The full V5 gate remains open.
The four-window/four-Spaces workload is deferred to V2 and does not block the
current goal.
