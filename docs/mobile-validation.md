# Mobile remote — validation record

- Date: 2026-09-17
- Scope: [PRD](mobile-poc-prd.md) acceptance list, [implementation plan](mobile-poc-implementation-plan.md) P5.
- Environment: Xcode 26.3, Swift 6.2, macOS 26.2 SDK, iOS 26.2 SDK, iPhone 16 Pro simulator on iOS 18.6, tmux from
  Homebrew, SwiftTerm 1.20.0, Chauffeur runtime `0.1.0-dev` (Debug).
- Physical iPhone: **not available during this pass.** Every item marked "device" below is still open and is the
  acceptance standard the PRD sets. Nothing in this record claims device behaviour.

## What was verified

### Automated (swift test, all green)

| Area | Coverage | Suite |
| --- | --- | --- |
| Wire protocol | Frame header bytes, split-chunk decoding, size/version/reserved rejection, every operation, result and event round trip with literal `kind` strings, launch fingerprint stability, pairing-code normalization and key derivation | `ChauffeurRemoteProtocolTests` |
| Terminal contract | Key encoding for every semantic key in normal and application-cursor modes, Control combinations, bracketed and plain paste, fake adapter input gating, conformance check | `ChauffeurTerminalInterfaceTests` |
| Client | Hello and version negotiation, unauthorized, request correlation and timeouts, ping/pong, framing errors, stale-generation frame drop, sequence-gap disconnect, `terminal_busy` → lost control with no retry, no reattach after control loss, input dropped while detached, resize debounce, pairing, operation journal reconciliation, stale inventory | `ChauffeurRemoteClientTests` |
| Runtime attachments | Bounded ordered pump, revoke stops delivery without closing, overflow ends the attachment once, second attach rejected without `takeControl`, takeover revokes the old client and rejects its stale input/resize while its stale detach is ignored | `AttachmentPumpTests`, `AttachmentGenerationTests` |
| Remote access service | Disabled by default, TLS-PSK listener, wrong key rejected, unknown/revoked device rejected, protocol mismatch, pairing flow and failure cap, revocation closes live connections, reset rotates the key, restart preserves pairing, full tmux round trip over TLS with response-before-output ordering and `terminal_busy` for a second client | `RemoteAccessServiceTests` |
| Host handlers | Inventory mapping (projects, presets, main and worktree checkouts, sessions), digest-driven revision, destination preview, `operation_conflict` on a changed payload, unknown-ID codes, journal persistence and restart reconciliation, idempotent shell launch in a new worktree with a real tmux session | `RemoteOperationHandlersTests` |
| End to end | The real client library over real TLS-PSK sockets against the real runtime and tmux: pair with the displayed code, hello, list inventory, launch a shell in a new worktree and repeat it idempotently, attach and see the shell execute typed input, take control from a second connection (loser disabled, cannot type, does not reattach on foreground, can take control back), unauthorized and revoked devices refused, a launch whose response is dropped is reconciled on reconnect to exactly one session and worktree, protocol mismatch reported, service restart preserves pairing | `RemoteEndToEndTests` (6 tests, three consecutive green runs) |
| Desktop regression | Existing suites unchanged; local IPC smoke (`Prototypes/runtime_smoke.py`) passes attach → input → reattach → resize with generations; it still fails at a pre-existing `terminalSnapshot` retention step that also fails on the base commit | `swift test`, smoke |

### Builds

- `swift build` and `swift test` for the package.
- macOS app (`Chauffeur` scheme) with the desktop terminal driven through `SwiftTermAdapter`.
- iOS app (`ChauffeurMobile` scheme) for the iOS 18.6 simulator; installed and launched, Connect screen rendered.
- Portable modules compiled for `arm64-apple-ios18.0-simulator` through SwiftPM.

### Transport spike (`Prototypes/psk-transport-spike`)

TLS 1.2 with `TLS_PSK_WITH_AES_128_GCM_SHA256` negotiated between an `NWListener` on macOS and an `NWConnection`
client compiled for and run inside the iOS 18.6 simulator; three 64 KiB frames verified in order; wrong key rejected
on both ends; TLS 1.3 PSK not supported by the API. See `RESULTS.md` there.

## PRD acceptance checklist status

| # | Scenario | Status |
| --- | --- | --- |
| 1 | Browse live sessions across two projects including one without a window; empty project selectable | Automated inventory mapping covers projects without sessions; simulator UI shows grouped sessions. Device: open. |
| 2 | Attach to Codex, Claude Code and shell sessions; prompts, approvals, Control-C, Escape, arrows, Tab, Unicode, copy/paste, scrollback, full-screen fixture | Shell round trip automated end to end over TLS (typed command executed, output returned). Key encoding automated with the fake adapter. Agent CLIs, Unicode on device, copy/paste and full-screen fixture: **device, open.** |
| 3 | Launch agent and shell in existing and new worktrees | Shell in a new worktree automated end to end from the client library; existing-checkout path and agent presets exercised through the same handler with fixtures. Device: open. |
| 4 | Multiple tabs, switching, closing leaves the process running | Tab model is local in the iOS app; closing detaches only. Device: open. |
| 5 | Transfer control both directions; only the owner types/resizes; redraw; unsent input preserved | Ownership transfer in both directions, stale rejection and no auto-reclaim automated end to end. Redraw and draft preservation depend on tmux and are **device/manual: open.** |
| 6 | Rotate and show/hide keyboard; correct dimensions | Resize path automated (adapter → controller → runtime). Device: open. |
| 7 | Wi-Fi loss, background/terminate, quit desktop UI; reconnect without duplicates or replayed keys | Input is never queued while detached (automated); reconnect logic automated with the in-memory transport. Real network loss and app termination: **device, open.** |
| 8 | Lose a launch response and retry → exactly one session and worktree; invalid ref; unavailable preset; launch failure after worktree creation | Lost response and retry automated end to end (one session, one worktree); conflict, invalid IDs and retained worktree automated at handler level. Invalid ref and agent-launch failure paths rely on existing desktop validation and are open on device. |
| 9 | Reject unauthorized or revoked devices; unreachable host; incompatible protocol | Automated. |

## Measurements

Not taken. The PRD's proposed targets (p95 shell input-to-echo under 150 ms, warm attachment under two seconds)
require a physical iPhone on Wi-Fi. The simulator spike shows sub-millisecond frame sends on loopback, which says
nothing about Wi-Fi latency.

## Known limitations

- No forward secrecy in the negotiated TLS suite; see [M1](decisions/M1-mobile-transport-and-terminal.md).
- `listInventory` always returns the full snapshot; `sinceRevision` is accepted but ignored.
- Inventory push is a one-second digest poll on the runtime, like the local subscribe stream.
- The desktop `reset()` on attach now clears local scrollback as well as the screen; tmux redraws the visible screen
  only, so scrollback before a reattach is reached through saved history, not the live buffer.
- Ghostty was not evaluated with a build spike; SwiftTerm is the only adapter.
- The iOS app UI has not been driven against a live runtime with UI automation; `RemoteEndToEndTests` exercises the same
  client library over the same sockets instead, and the simulator run only confirms the app launches.
