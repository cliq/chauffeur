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

## Native fixture evidence

`Scripts/build-app.sh` and `Scripts/build-app.sh Release` succeed.
`codesign --verify --deep --strict` validates the local app and its embedded
binaries; Release helpers are signed with hardened runtime enabled. This is local signing, not distribution
signing/notarization.

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

The probe drives native view methods directly. Its cached-view images can show
terminal pixels but do not reliably capture every layer of a SwiftUI window.
They do not establish OS keyboard, accessibility, notification, or Spaces behavior.

## OS automation attempt

The Xcode `ChauffeurAppUITests` target builds. Its runner requires hardened
runtime disabled for the locally signed UI-test bundle; the app retains hardened
runtime. The test runner then times out before test execution while enabling
macOS Automation Mode. `automationmodetool` reports that user authentication is
required; `DevToolsSecurity -status` reports Developer mode disabled. These system
settings were left unchanged, and the user was asked to enable UI-testing access.
The user has said they will enable access. The latest check still reports both
Automation Mode and Developer mode disabled; XCUITest has not yet run.

## Remaining gate evidence

- Verify actual `SMAppService` registration and launchd restart from the app.
  The direct fixture uses `CHAUFFEUR_SOCKET` and bypasses registration.
- Run XCUITest, native keyboard/copy/paste/find/link and accessibility interactions.
- Place four windows on separate Spaces; confirm focus, frames and restoration.
- Validate sleep/wake, service loss, notifications, and notification routing when
  the UI is closed.
- Repeat lifetime scenarios with both real CLIs and their intended accounts.

The full V5 gate remains open.
