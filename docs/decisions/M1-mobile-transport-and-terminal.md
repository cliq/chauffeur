# M1 — Mobile remote: transport, terminal engine, and pairing

Status: decided on 2026-09-17 for the [mobile POC](../mobile-poc-prd.md) per the
[implementation plan](../mobile-poc-implementation-plan.md). Physical-device
evidence is recorded in the validation document as it is gathered; simulator and
in-process evidence is listed below.

## Transport

The Mac runtime and the iPhone talk over a **TLS connection with a pre-shared key
(PSK)** carried by Apple's Network.framework on both sides (`NWListener` on the
runtime, `NWConnection` on iOS). No X.509 certificate, no WebSocket, no new
package dependency.

Why not a certificate: `NWListener` needs a `sec_identity_t`, which on macOS only
comes from a keychain `SecIdentity`. The background runtime is a headless launchd
agent whose executable is re-signed and atomically replaced on every install (see
[V5](V5-macos-lifetime.md)), and Debug builds are ad-hoc signed. Keychain ACLs are
bound to the signing identity, so every helper replacement would risk a
"wants to access key" prompt from a process that has no UI. A PSK removes the
identity entirely: possession of the key authenticates both directions, so host
verification and device authorization collapse into one primitive with nothing to
display, type, or pin.

Fallback if PSK negotiation ever fails on a supported OS: a NIOSSL server with a
self-issued P-256 certificate (swift-certificates is already resolved) and leaf
pinning on the client. It changes only the listener and pairing client, not the
framing, protocol module, or runtime attachment work.

Spike evidence (2026-09-17, `Prototypes/psk-transport-spike/RESULTS.md`): an
`NWListener` and `NWConnection` on macOS 26 negotiate **TLS 1.2 with
`TLS_PSK_WITH_AES_128_GCM_SHA256`** (0x00A8) using
`sec_protocol_options_add_pre_shared_key` plus
`sec_protocol_options_append_tls_ciphersuite` with the legacy constant and the TLS
version pinned to 1.2. The same client compiled for the iOS 18.6 simulator and run
inside it negotiated the same suite against the Mac listener and verified three
64 KiB frames in order. A wrong key fails the handshake on both ends (client
`.waiting` with a TLS error, server `.failed`) with no frame delivered, so clients
must treat a TLS error in `.waiting` as terminal. TLS 1.3 PSK is **not** supported by
this API. The negotiated suite has **no forward secrecy**: a leaked pairing key
exposes recorded sessions. This is accepted for a personal LAN POC; the
`Reset remote access` action rotates the key, and the runtime never logs it.

### Framing

Every frame has an 8-byte big-endian header: `version` (1 byte, `1`), `type`
(1 byte), `reserved` (2 bytes, must be 0), `payloadLength` (4 bytes). Types:
1 request, 2 response, 3 event, 4 terminal output, 5 terminal input, 6 ping,
7 pong. Types 1–3 carry JSON envelopes from `ChauffeurRemoteProtocol`; types 4–5
carry a 16-byte subheader (`generation` UInt64, `sequence` UInt64) followed by raw
terminal bytes. The generation is server-assigned and globally unique, so binary
frames do not carry a session ID; the client maps generation to session from the
attach result and drops frames whose generation is not its current one.

Limits: payloads above 4 MiB are a protocol error and close the connection;
terminal chunks are capped at 64 KiB by the producer. Each attachment has a bounded
queue (1 MiB or 256 chunks). On overflow the runtime ends that attachment with
reason `slowConsumer` instead of dropping bytes; the client reattaches and tmux
redraws the screen.

## Pairing and authorization

Remote access is off by default and lives in the runtime, not the desktop app, so
it survives quitting every window.

- **Main listener**: default port 51847 (Release) / 51848 (Debug), PSK =
  `remoteAccessKey` (32 random bytes). The first frame after the handshake is
  `hello` with a `deviceID` and `deviceToken`; the runtime compares the token's
  SHA-256 against its device list. Unknown or revoked devices are disconnected
  before any inventory, launch, or terminal access.
- **Pairing listener**: main port + 1, opened only while pairing is active
  (120 s or one successful pairing). Its PSK is derived from a 10-character
  Crockford base32 code shown on the Mac (about 50 bits, so a captured handshake
  cannot be brute-forced offline). The `pair` operation returns the
  `remoteAccessKey`, a fresh device ID and token, the main port and host identity.
  The pairing listener stops after 5 failed handshakes.
- **Revocation** removes the device record, closes its live connections, and
  detaches its terminals. **Reset** rotates the PSK so every device must pair again.
- **Storage**: `<data root>/runtime/remote-access.json` with mode 0600 inside the
  existing 0700 `runtime/` directory (raw PSK, hashed device tokens). The Debug and
  Release runtimes already use separate data roots and now separate default ports.
  iOS keeps its credentials in the Keychain under a bundle-suffixed service name.

Rate limits on the main listener: 8 concurrent connections, 5 failed `hello`
attempts per source address per minute, 10 s handshake deadline.

## Terminal engine

**SwiftTerm 1.20.0 is the first adapter on iOS**, the same engine and version the
desktop uses. It is wrapped behind `ChauffeurTerminalInterface`, an engine-neutral
`@MainActor` contract: feed ordered bytes, reset, focus, dispose, configure
font/theme/scrollback, report generated input and cell size, and encode semantic
keys (Escape, arrows, Control, Tab, paste) according to the engine's live modes.
SwiftTerm types never leave `ChauffeurTerminalSwiftTerm` (iOS) or the desktop's
adapter file. A `FakeTerminalEngineAdapter` proves the client compiles and its tests
run with no engine.

Facts that shaped the boundary: SwiftTerm's `sendKeyUp/Down/...` are internal, so
arrows and control keys are encoded by the interface module from `applicationCursor`
and `bracketedPasteMode`; `feed` is main-thread only; the iOS view already disables
autocorrection, smart quotes and capitalization.

Ghostty remains under consideration. It was not evaluated with a build spike in this
increment; a future adapter must pass the conformance check and the fixture tests
without changing the wire protocol or session logic.

## Platform decisions

- Minimum iOS **18.0**. Only iOS 18.6 and 26.x simulators are installed, so an
  earlier minimum would be untestable.
- No Bonjour in the POC: manual host and port entry. Only
  `NSLocalNetworkUsageDescription` is declared; `NSBonjourServices` is added only if
  a device test shows the local-network prompt is not triggered by a plain TCP
  connection.
- Bundle identifier `dev.cliq.chauffeur.mobile` with the existing `.debug` suffix
  in Debug, so Debug and Release pairings stay separate on the phone too.
