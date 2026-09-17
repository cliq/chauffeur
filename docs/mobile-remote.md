# Mobile remote control

- Date: 2026-09-17
- Status: POC in progress. Requirements: [mobile POC PRD](mobile-poc-prd.md).
  Technical decisions: [M1 transport and terminal](decisions/M1-mobile-transport-and-terminal.md).

## 1. What it is

The Chauffeur iPhone app (`ChauffeurMobile`) is a remote client of the Mac's
background runtime. It browses active sessions across projects, attaches to
their real terminals, and launches new agent or shell sessions. The Mac stays
the execution host and source of truth: repositories, worktrees, CLI
installations, credentials, and processes all remain on the Mac. The phone
never runs a CLI or holds a checkout of its own.

The phone and Mac must be on the same local network. There is no internet
connectivity, relay, cloud account, or support for pairing with more than one
Mac at a time.

This is a proof of concept, not a finished feature. Final visual design, an
optimized iPad layout, App Store distribution, project/preset editing,
worktree deletion, session-history management, split panes, file browsing,
notifications, and simultaneous terminal writers are all explicitly deferred;
see the PRD's [deferred scope](mobile-poc-prd.md#8-explicitly-deferred) for the
complete list.

The iOS app in this tree is wired to the real remote client: pairing, the
session list, launches and terminals go through `ChauffeurRemoteClient` over the
TLS connection described below, and the terminal surface is the SwiftTerm
adapter (`--fake-terminal` swaps in the fake engine for previews and tests).
What has and has not been verified is recorded in
[mobile-validation.md](mobile-validation.md); physical-iPhone checks are still
open, so where this doc describes device behaviour it is the intended contract,
not an observed result.

## 2. Building

Regenerate the Xcode project after pulling changes, since `project.yml` defines
the `ChauffeurMobile` target and scheme:

```sh
xcodegen generate
```

`ChauffeurMobile` is an iOS application target with a deployment target of
**iOS 18.0** (the only simulators installed for this project are iOS 18.6 and
26.x, so an earlier minimum would be untestable). Build for the simulator with:

```sh
xcodebuild -scheme ChauffeurMobile -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build
```

A physical-device build additionally needs a `DEVELOPMENT_TEAM` in
`Configuration/LocalSigning.xcconfig` (copy it from
`Configuration/LocalSigning.xcconfig.example` if you haven't already; see
[building and verifying](building.md#signing)). The app's bundle identifier is
`dev.cliq.chauffeur.mobile`, with the existing `.debug` suffix appended in
Debug builds, so Debug and Release installs pair separately even on the same
phone.

Debug and Release stay paired with their matching Mac runtime: the Debug phone
app talks to the `Chauffeur Debug` runtime on port 51848, and the Release phone
app talks to the Release runtime on port 51847 (see
[Debug and Release side by side](building.md#debug-and-release-side-by-side)).
Pairing a Debug phone build with a Release Mac, or vice versa, will not work.

## 3. Enabling remote access and pairing

Remote access is off by default and lives in the Mac's background runtime, not
the desktop app, so it stays available after quitting every project window.
Turn it on from **Settings → Remote Access** on the Mac:

- **Allow remote access** toggle starts the listener.
- Once listening, the section shows the addresses and port it's listening on,
  and a **Key fingerprint** (the first 8 bytes of SHA-256 of the access key, in
  hex) that you can use to confirm you're pairing with the Mac you expect.
- **Pair iPhone…** starts a pairing window and shows a code as
  `XXXX-XXXX-XX` (10 characters, Crockford base32) with a live countdown. The
  code, and the pairing listener that uses it, expire after **120 seconds** or
  one successful pairing, whichever comes first.
- **Reset Remote Access…** rotates the access key and removes every paired
  device; every iPhone has to pair again afterward.
- Each paired device is listed with **Revoke**, which removes that one device
  and disconnects it without affecting others.
- The port can only be changed while remote access is off, using the port
  field and **Apply**.

On the phone, enter the Mac's address — either its IPv4 address or its
`name.local` hostname — and port, then enter the pairing code shown on the Mac
(`ConnectView`/`PairingSheet` format and validate it as `XXXX-XXXX-XX`).
Automatic discovery (Bonjour) is not used in the POC; address and port entry
are manual.

What each side stores:

- The Mac keeps `<data root>/runtime/remote-access.json`, mode 0600 inside the
  0700 `runtime/` directory. It holds the raw pre-shared access key and, per
  device, a SHA-256 hash of that device's bearer token — never the token
  itself.
- The phone keeps its device ID, device token, and the Mac's access key in the
  Keychain, under a bundle-suffixed service name so Debug and Release builds
  don't share credentials.

**Revoke** removes one device's record, closes its live connections, and
detaches its terminals, without affecting the access key or other devices.
**Reset** instead rotates the shared access key itself, which invalidates
every device at once and requires re-pairing all of them.

## 4. Using it

**Sessions** lists live sessions grouped by project, across every project —
including ones without an open desktop window. Selecting a session opens its
terminal.

**Take Control**: only one client — desktop or phone — controls a session's
terminal input and size at a time. Taking control is an explicit, visible
handoff in both directions: the side that loses control sees a "Terminal is
attached on \<device\>" banner with a **Take control** action, and it never
reclaims control automatically after a deliberate transfer. The controlling
client owns the terminal's size.

Tabs (which sessions are open, and in what order) are local to each device;
they are not synchronized between the phone and the Mac. Opening an existing
session does not start a new process — it just attaches to what's already
running. Closing a tab on the phone only detaches that tab's view; it does not
stop the underlying process.

On disconnect (Wi-Fi loss, backgrounding, or the Mac becoming unreachable),
terminal input is disabled and the screen shows the last known state as not
live. Reconnecting reattaches to the same process and refreshes the current
screen; the app never queues keystrokes while offline or replays them on
reconnect. The sessions list shows a stale-data banner ("Disconnected · Last
known list, not live", with a "Stale since \<time\>" caption) whenever the
shown inventory might no longer be current, and a **Disconnect**/**Reconnect**
action to recover.

## 5. Recovery and troubleshooting

- **Mac asleep or unreachable**: the phone shows an unavailable/disconnected
  state rather than a stale live view; reconnect once the Mac is awake and
  reachable. Wake-on-LAN is out of scope, so the Mac must already be awake.
- **Runtime restart**: pairing survives a runtime restart because
  `remote-access.json` is persisted on disk. `RemoteOperationHandlers` also
  reconciles any launch or worktree-creation operation left mid-flight by the
  previous process on the next status check or retry, resolving it to
  completed, worktree-ready, or a retryable "interrupted" failure rather than
  duplicating work.
- **Protocol mismatch**: the phone and Mac exchange a `protocolVersion` in the
  connection handshake and framing header; a mismatch means the two builds
  disagree on the wire format and both apps need to be updated to matching
  versions.
- **Revoked device**: a revoked or unknown device's token hash no longer
  matches the Mac's device list, so the connection is closed before it can
  list, launch, or attach to anything.
- **Wrong pairing code**: the pairing listener's TLS pre-shared key is derived
  from the code itself, so a wrong code fails the TLS handshake rather than
  producing an application-level error; the pairing listener also stops after
  5 failed handshakes.
- **Key fingerprint check**: compare the fingerprint shown in **Settings →
  Remote Access** on the Mac against what you expect before trusting a pairing
  or an existing connection — it's a stable, safe-to-share identifier for the
  Mac's access key.
- For anything not explained by the state shown on screen, see
  [service recovery](service-recovery.md) for background-runtime recovery
  behavior in general, and [diagnostics](diagnostics.md) for exporting a
  redacted report (protocol version, runtime state, recent error codes) from
  either the desktop app or `chauffeurctl diagnostics`.

## 6. Security notes

The connection is TLS with a pre-shared key (PSK), carried by Apple's
Network.framework on both sides (`NWListener` on the runtime, `NWConnection`
on iOS); this negotiates TLS 1.2 with `TLS_PSK_WITH_AES_128_GCM_SHA256`
(TLS 1.3 PSK isn't supported by this API). This suite has **no forward
secrecy** — a leaked access key exposes any recorded sessions — which is
accepted for a personal-LAN POC. See
[M1 — transport](decisions/M1-mobile-transport-and-terminal.md#transport) for
the full rationale and the certificate-based fallback if PSK negotiation ever
fails on a supported OS.

Remote access never exposes the local Unix-socket IPC interface or an
unauthenticated shell to the network. It's a separate, authenticated listener
with an explicit operation allowlist (inventory, worktree preview, launch,
operation status, terminal attach/resize/detach); remote clients cannot
dispatch arbitrary local IPC methods or reach arbitrary filesystem paths.

The main listener rate-limits connections: 8 concurrent connections, 5 failed
`hello` attempts per source address per minute, and a 10-second handshake
deadline. The separate pairing listener stops after 5 failed handshakes and
closes after 120 seconds or one successful pairing.

## 7. Replacing the terminal engine

SwiftTerm is the current terminal engine on both desktop and iOS, but the
architecture keeps it replaceable — Ghostty is under consideration as a future
engine. All session/launch/transport logic talks to the terminal only through
`TerminalEngineAdapter` (`Sources/ChauffeurTerminalInterface/TerminalEngineAdapter.swift`),
an engine-neutral, `@MainActor` contract: feed ordered output bytes, reset for
a fresh attachment, focus, dispose, configure appearance, report generated
input bytes and cell size, and encode semantic key actions
(`TerminalKeyAction`) using the engine's live modes. SwiftTerm types never
leave `ChauffeurTerminalSwiftTerm`; nothing outside that module may
`import SwiftTerm`.

`TerminalCapabilities` (`Sources/ChauffeurTerminalInterface/TerminalCapabilities.swift`)
is an `OptionSet` describing optional features (selection, clipboard copy,
links, bell, mouse reporting, title, bracketed paste, scrollback, search).
`.required` lists what every production adapter must provide; the app can gate
functionality on a capability without knowing which engine is active.
`TerminalAdapterConformance.check(_:)` is a runtime diagnostic that flags an
adapter missing required capabilities or one whose `makeView()` doesn't return
a stable view instance.

`FakeTerminalEngineAdapter` (`Sources/ChauffeurTerminalTesting`) implements the
same contract with no rendering engine at all, so session/connection logic can
compile and run in tests, and the iOS app can run UI-only builds (via a
`--fake-terminal` launch argument), without SwiftTerm.

A Ghostty adapter would need to implement `TerminalEngineAdapter` end to end
inside its own module (mirroring `ChauffeurTerminalSwiftTerm`), including
mode-aware key/paste encoding — SwiftTerm's key-sending API is internal, so
the interface module encodes arrows/control keys itself from the adapter's
reported `applicationCursor`/`bracketedPasteMode` state — and pass
`TerminalAdapterConformance.check(_:)` plus the manual checks documented in
[`SwiftTermAdapter`'s header comment](../Sources/ChauffeurTerminalSwiftTerm/SwiftTermAdapter.swift):
keyboard input round-tripping through the delegate exactly once per key with no
local echo, correct escape sequences for arrows/backspace in both normal and
application-cursor modes, bracketed-paste framing, no replay after
`setInputEnabled(false)`/`true`, correct cell-size reporting on rotation/resize,
title/bell/clipboard-copy/link events, a clean `reset()` and redraw, and
`selectedText()` behavior. See
[M1 — terminal engine](decisions/M1-mobile-transport-and-terminal.md#terminal-engine)
for the constraints that shaped this boundary and the current engine decision.
