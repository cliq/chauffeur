# PSK transport spike — results

Question: can Apple's Network.framework carry an authenticated, encrypted LAN link between a macOS
`NWListener` and an iOS `NWConnection` using TLS with a pre-shared key and **no X.509 certificate**,
then exchange custom length-prefixed binary frames?

**Answer: yes, with TLS 1.2 and the `TLS_PSK_WITH_AES_128_GCM_SHA256` ciphersuite. TLS 1.3 PSK does not work
through this API.**

Environment: Xcode 26.3 (17C529), Swift 6.2.4, macOS 26 host, iOS Simulator SDK 26.2, booted iPhone 16 Pro
simulator running iOS 18.6 (22G86), UDID `81DDC533-25FE-4A08-8617-9295EE938370`. Swift 6 language mode,
strict concurrency, no third-party dependencies.

## Summary

| Part | Result | Detail |
|------|--------|--------|
| 1. In-process self-test (`swift run psk-spike`) | PASS (exit 0) | TLS 1.2 PSK handshake, hello/ack, 3 x 64 KiB frames verified by SHA-256 on both ends; wrong PSK rejected with zero frames delivered |
| 2. iOS simulator client vs macOS listener | PASS | `simctl spawn` ran the arm64 simulator binary; negotiated `0x0303 / 0x00a8`, all frames verified, exit 0 on both sides |
| 3. This document | done | |
| Info: TLS 1.3 PSK (`.TLSv13` + `.AES_128_GCM_SHA256`) | does not work | client `-9858 handshake failed`, server `-9816 server closed session with no notification` |
| Info: PSK suite with max TLS version left at default | works | still negotiates TLS 1.2 / 0x00a8 (the PSK suite forces 1.2) |

## Working snippet (identical on listener and client)

```swift
import Network
import Security

let pskIdentity = "chauffeur-remote"   // short ASCII string; both sides use the same one

func makeParameters(psk: Data /* 32 random bytes */) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions

    let pskDispatchData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
    let identityDispatchData = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(sec,
                                            pskDispatchData as __DispatchData,
                                            identityDispatchData as __DispatchData)

    // tls_ciphersuite_t has NO PSK cases. Build it from the legacy SecureTransport constant (0x00A8).
    // Imported C enums accept any raw value, so the `!` never fires.
    let pskSuite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!   // == 0x00A8
    sec_protocol_options_append_tls_ciphersuite(sec, pskSuite)
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: tls, tcp: tcp)
}

// Listener (macOS)
let params = makeParameters(psk: psk)
params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)   // port 0 / ephemeral
let listener = try NWListener(using: params)
// listener.port?.rawValue is valid once state == .ready

// Client (iOS)
let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: makeParameters(psk: psk))

// After .ready, on either side:
if let md = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
    let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(md.securityProtocolMetadata) // .TLSv12 (0x0303)
    let suite   = sec_protocol_metadata_get_negotiated_tls_ciphersuite(md.securityProtocolMetadata)      // rawValue 0x00A8
}
```

Nothing else was required: no `sec_protocol_options_set_peer_authentication_required`, no
`set_pre_shared_key_selection_block`, no verify block, no identity/certificate, no
`sec_protocol_options_set_tls_server_name`.

Framing used: 8-byte big-endian header (`version: UInt8 = 1`, `type: UInt8`, `reserved: UInt16 = 0`,
`payloadLength: UInt32`) followed by the payload. Reads use
`receive(minimumIncompleteLength: n, maximumLength: n)` twice (header, then payload) — with min == max
Network.framework delivers exactly `n` bytes or an error, so no reassembly buffer is needed. Writes use
`send(content:completion: .contentProcessed)` and await the completion before the next frame; three
64 KiB frames each completed in 0.1–0.3 ms on loopback.

## Negotiated parameters

Both sides, in-process and macOS<->simulator:

- TLS protocol version: `0x0303` = **TLS 1.2**
- Ciphersuite: `0x00A8` = **TLS_PSK_WITH_AES_128_GCM_SHA256** (RFC 5487)

### Forward secrecy

**No.** `TLS_PSK_WITH_*` (plain PSK key exchange) derives the session keys from the PSK plus the two
handshake randoms only. Anyone who records traffic and later obtains the PSK can decrypt every past
session. The forward-secret variants (`TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256` = 0xD001,
`TLS_DHE_PSK_*`) were not exercised in this spike; Apple's TLS stack historically does not enable
`ECDHE_PSK` for TLS 1.2, and TLS 1.3 PSK+ECDHE does not work here (see below). Mitigation if it
matters: rotate the PSK per pairing/session (e.g. derive a per-session PSK from a long-term pairing
secret with HKDF and a nonce exchanged out-of-band or in a first cleartext frame).

## Wrong-PSK behaviour

In-process, and again from the simulator, with a second random 32-byte PSK and the same identity:

- Client: `.waiting(-9820: bad MAC)` (`errSSLPeerBadRecordMac`). It never reaches `.ready`. Note it is
  **`.waiting`, not `.failed`** — Network.framework treats the TLS alert as potentially transient, so the
  connection would sit there retrying until `cancel()`. Production code must treat `.waiting` with an
  `NWError.tls` as fatal and cancel (the spike does this via a 5 s timeout + cancel).
- Server: the listener's `newConnectionHandler` **is called** (TCP accept happens before the TLS
  handshake), then the connection goes `.failed(-9846: bad MAC)` (`errSSLBadRecordMac`) after `start()`.
  `framesReceived` stayed 0; `receive` never delivered anything. So a server must be prepared to see
  accepted connections that never become `.ready`, and must not trust a connection before `.ready`.
- Total time to rejection: well under a second on loopback (one handshake round trip).

Server-side the PSK is looked up by identity: with `sec_protocol_options_add_pre_shared_key` on the
listener the server matches the client's offered identity against the ones added. A differing identity
is expected to fail the same way (not measured separately here).

## TLS 1.3 variant

Options: `sec_protocol_options_append_tls_ciphersuite(sec, .AES_128_GCM_SHA256)`, min/max `.TLSv13`,
same `add_pre_shared_key` call.

Result: **fails.** Client `.waiting(-9858: handshake failed)`, server `.failed(-9816: server closed
session with no notification)`. `sec_protocol_options_add_pre_shared_key` only feeds the TLS 1.2 PSK
ciphersuites; the TLS 1.3 external-PSK path (`pre_shared_key` extension, RFC 8446 §4.2.11) is not
exposed by this API. Leaving the max version unpinned (min 1.2, default max) still works and negotiates
1.2, because the only enabled suite is a 1.2 suite, but pin the max to `.TLSv12` anyway to make the
intent explicit.

## iOS simulator run

Build (single-file client, Foundation + Network + CryptoKit only):

```
xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -O \
    -o .build/ios-client Sources/psk-spike-client/main.swift
```

Compiled first try against the 26.2 simulator SDK with an iOS 18.0 deployment target; `file` reports
`Mach-O 64-bit executable arm64`, which matches the simulator's runtime arch on Apple silicon.

Run:

```
swift run psk-spike --serve <pskhex>            # prints "PORT <n>", serves one client, exits 0/1
xcrun simctl spawn 81DDC533-25FE-4A08-8617-9295EE938370 .build/ios-client 127.0.0.1 <n> <pskhex>
```

Result: `simctl spawn` ran the binary without issue (`ProcessInfo` reported iOS 18.6 / 22G86). The client
connected to the macOS listener on `127.0.0.1` (the simulator shares the host's loopback), negotiated
`version=0x0303 ciphersuite=0x00a8`, completed hello/ack, received the three 64 KiB frames in order, and
the server verified the returned SHA-256 digests. Both processes exited 0. With a wrong PSK the simulator
client got `.waiting(-9820: bad MAC)` and exited 1; the server logged `.failed(-9846: bad MAC)`.

The same client source also builds and runs as the macOS SwiftPM target `psk-spike-client`.

## Gotchas

1. **Ciphersuite constant.** `tls_ciphersuite_t` (the Swift enum backing `sec_protocol_options_append_tls_ciphersuite`)
   has no PSK cases. Use `tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!` (the
   constant lives in `Security/CipherSuite.h`, value `0x00A8`), or the literal `tls_ciphersuite_t(rawValue: 0x00A8)!`.
   The `TLS_PSK_...` SecureTransport constants are not deprecated-annotated in the 26.x SDK; no warning.
2. **`DispatchData` bridging.** The C API takes `dispatch_data_t`; pass `DispatchData ... as __DispatchData`.
3. **TLS 1.3 PSK is not available** through `sec_protocol_options_add_pre_shared_key`. Pin min = max = `.TLSv12`.
4. **Wrong PSK surfaces as `.waiting`, not `.failed`, on the client.** Handle `.waiting(NWError.tls(...))` as terminal.
5. **The server sees an accepted `NWConnection` before authentication.** Do not associate state with a connection
   until `.ready`; expect `.failed` on some accepted connections.
6. **`sec_protocol_options_set_peer_authentication_required` was not needed.** PSK authentication is mutual by
   construction (both sides prove knowledge of the key via the Finished MACs). Do not call
   `sec_protocol_options_set_peer_authentication_required(sec, false)`; there is no certificate to skip.
7. **No forward secrecy** with `TLS_PSK_WITH_*` — see above. Rotate/derive per-session keys if this matters.
8. **Exact-length reads:** `receive(minimumIncompleteLength: n, maximumLength: n)` returns exactly `n` bytes or an
   error, so header-then-payload framing needs no partial-buffer bookkeeping. A zero-length payload must skip
   the second `receive` (min 0 would return immediately with nil content).
9. **Concurrency.** `NWConnection`/`NWListener` are not `Sendable` in the 26.x SDK; wrapping them in
   `final class ...: @unchecked Sendable` with a resume-once guard around `stateUpdateHandler` ->
   `CheckedContinuation` compiles cleanly in Swift 6 language mode with zero warnings. Continuation-based
   send/receive are not cancellable, so a timeout must also `cancel()` the connection.
10. **Real device (not simulator) notes.** The simulator shares the Mac's loopback, so `127.0.0.1` works
    and no Local Network permission is involved. On a physical iPhone: the client must connect to the Mac's
    LAN address (or a Bonjour service), iOS 14+ shows the Local Network privacy prompt on first use and
    requires `NSLocalNetworkUsageDescription` in Info.plist (and `NSBonjourServices` if browsing via Bonjour);
    the macOS listener should bind `.any`/the LAN interface rather than `127.0.0.1`, and macOS 15+ has its
    own Local Network prompt for the server app when it advertises/accepts on the LAN. None of that affects
    the TLS-PSK layer itself.
11. **PSK size/identity.** 32 random bytes as the PSK and a short ASCII identity work. Do not derive the PSK
    from a low-entropy human passcode directly (offline brute force of the handshake MAC is possible); if a
    passcode is the pairing UX, run it through a proper PAKE or at least a KDF with a random salt exchanged
    separately.

## Recommendation

Adopt Network.framework with TLS 1.2 + `TLS_PSK_WITH_AES_128_GCM_SHA256` as the Chauffeur remote transport:
it needs no certificate provisioning, works unchanged on macOS and iOS (simulator verified, same
`NWParameters` code on both sides), the wrong-key case fails fast and cleanly, and the custom 8-byte frame
protocol maps directly onto `receive(minimumIncompleteLength:maximumLength:)` with `.contentProcessed`
backpressure. Treat the PSK as a per-pairing secret of 32 random bytes exchanged out of band (QR code /
deep link), treat client `.waiting` TLS errors as fatal, and, because the suite lacks forward secrecy,
derive a fresh per-session PSK from the pairing secret (HKDF + nonce) rather than reusing one static key
indefinitely.

## Files

- `Package.swift` — swift-tools-version 6.2, macOS 15, two executable targets
- `Sources/psk-spike/` — `TLS.swift` (options), `Framing.swift`, `Peer.swift` (NWConnection/NWListener wrappers),
  `Roles.swift` (server/client halves), `main.swift` (self-test, `--serve`)
- `Sources/psk-spike-client/main.swift` — single-file client, compiles for the iOS simulator with `swiftc`
- Reproduce: `swift run psk-spike` (exit 0 = PASS), then the `--serve` / `simctl spawn` commands above
