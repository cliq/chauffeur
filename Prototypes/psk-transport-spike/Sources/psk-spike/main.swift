import Foundation
import Network

// psk-spike: proves Network.framework TLS-PSK (no certificates) between NWListener and NWConnection.
//
//   swift run psk-spike                  self-test (positive, negative, TLS 1.3 variant) in one process
//   swift run psk-spike --serve <pskhex> [--tls13]
//                                        server-only: listen on 127.0.0.1:<ephemeral>, print "PORT <n>",
//                                        serve one client (e.g. the iOS simulator client), exit 0 on success

struct Outcome: Sendable {
    var name: String
    var passed: Bool
    var detail: String
}

final class Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Outcome] = []
    var all: [Outcome] { lock.withLock { items } }
    func record(_ name: String, _ passed: Bool, _ detail: String) {
        lock.withLock { items.append(Outcome(name: name, passed: passed, detail: detail)) }
        log("\n==> \(passed ? "PASS" : "FAIL") \(name): \(detail)\n")
    }
}
let outcomes = Outcomes()
func record(_ name: String, _ passed: Bool, _ detail: String) { outcomes.record(name, passed, detail) }

/// Runs both halves in-process against `server` with `psk`, returns detail text on success, throws otherwise.
func runPositive(server: Server, port: UInt16, psk: Data, flavor: TLSFlavor, label: String) async throws -> String {
    let client = makeClient(port: port, psk: psk, flavor: flavor, label: "\(label)-client")
    defer { client.cancel() }

    // The server half needs the accepted connection; accept concurrently with the client's start.
    async let serverSide: (RoleResult, [Data]) = withTimeout(20, "server half") {
        guard let peer = await server.nextConnection() else { throw SpikeError.cancelled }
        defer { peer.cancel() }
        return try await runServerHalf(peer)
    }
    async let clientSide: (RoleResult, [Data]) = withTimeout(20, "client half") {
        try await runClientHalf(client)
    }
    let (s, c) = try await (serverSide, clientSide)
    guard s.1 == c.1 else { throw SpikeError.verification("in-process hash lists differ") }
    return "server TLS \(s.0.tls); client TLS \(c.0.tls); \(dataFrameCount) x \(dataBodySize) B frames verified by both sides"
}

/// Connects with a different PSK; succeeds (returns detail) only if the handshake is rejected and no frame reaches the server.
func runNegative(server: Server, port: UInt16, flavor: TLSFlavor) async throws -> String {
    let wrongPSK = Data.random(count: 32)
    let client = makeClient(port: port, psk: wrongPSK, flavor: flavor, label: "wrong-psk-client")
    defer { client.cancel() }

    // Server side: accept + start whatever arrives; it must never yield a frame.
    let serverSide = Task<String, Never> {
        do {
            let peer = try await withTimeout(5, "wrong-psk accept") { () -> Peer in
                guard let p = await server.nextConnection() else { throw SpikeError.cancelled }
                return p
            }
            defer { peer.cancel() }
            do {
                try await withTimeout(5, "wrong-psk server handshake") { try await peer.start(timeout: 5) }
                // Handshake "succeeded"?! Try to read a frame; it must fail.
                let frame = try await withTimeout(5, "wrong-psk server receive") { try await peer.receiveFrame() }
                return "SERVER GOT FRAME type=\(frame.header.type) len=\(frame.payload.count)"
            } catch {
                return "server side rejected: \(error); framesReceived=\(peer.framesReceived)"
            }
        } catch {
            return "server side never saw a TLS-ready connection (\(error))"
        }
    }

    var clientDetail: String
    do {
        try await withTimeout(5, "wrong-psk client handshake") { try await client.start(timeout: 5) }
        clientDetail = "CLIENT BECAME READY (unexpected), TLS \(client.connection.negotiatedTLS().map(String.init(describing:)) ?? "n/a")"
    } catch {
        clientDetail = "client rejected: \(error)"
    }
    let serverDetail = await serverSide.value
    let clientOK = clientDetail.hasPrefix("client rejected")
    let serverOK = !serverDetail.hasPrefix("SERVER GOT FRAME")
    let detail = "\(clientDetail); \(serverDetail); final client state \(describe(client.lastState))"
    guard clientOK && serverOK else { throw SpikeError.verification(detail) }
    return detail
}

func selfTest() async -> Int32 {
    let psk = Data.random(count: 32)
    log("PSK (32 random bytes): \(psk.hexString)")
    log("PSK identity: \(pskIdentity)")

    // --- TLS 1.2 PSK listener: positive + negative ---
    do {
        let server = try Server(psk: psk, flavor: .tls12PSK)
        let port = try await server.start()
        log("TLS1.2-PSK listener on 127.0.0.1:\(port)")
        defer { server.cancel() }

        do {
            let detail = try await runPositive(server: server, port: port, psk: psk, flavor: .tls12PSK, label: "tls12")
            record("positive TLS1.2 PSK handshake + frames", true, detail)
        } catch {
            record("positive TLS1.2 PSK handshake + frames", false, "\(error)")
        }

        do {
            let detail = try await runNegative(server: server, port: port, flavor: .tls12PSK)
            record("negative wrong PSK rejected", true, detail)
        } catch {
            record("negative wrong PSK rejected", false, "\(error)")
        }
    } catch {
        record("TLS1.2 PSK listener start", false, "\(error)")
    }

    // --- TLS 1.3 variant (informational; does not gate exit code) ---
    var tls13Detail: String
    var tls13Passed = false
    do {
        let server = try Server(psk: psk, flavor: .tls13PSK)
        let port = try await server.start()
        log("TLS1.3-PSK listener on 127.0.0.1:\(port)")
        defer { server.cancel() }
        do {
            tls13Detail = try await runPositive(server: server, port: port, psk: psk, flavor: .tls13PSK, label: "tls13")
            tls13Passed = true
        } catch {
            tls13Detail = "\(error)"
        }
    } catch {
        tls13Detail = "listener start failed: \(error)"
    }
    log("\n==> INFO TLS1.3 PSK variant: \(tls13Passed ? "WORKS" : "DOES NOT WORK") — \(tls13Detail)\n")

    // --- Informational: PSK suite with max version left at default ---
    var noPinDetail: String
    var noPinPassed = false
    do {
        let server = try Server(psk: psk, flavor: .tls12PSKNoMaxPin)
        let port = try await server.start()
        log("TLS1.2-PSK (no max pin) listener on 127.0.0.1:\(port)")
        defer { server.cancel() }
        do {
            noPinDetail = try await runPositive(server: server, port: port, psk: psk, flavor: .tls12PSKNoMaxPin, label: "nomaxpin")
            noPinPassed = true
        } catch {
            noPinDetail = "\(error)"
        }
    } catch {
        noPinDetail = "listener start failed: \(error)"
    }
    log("\n==> INFO PSK suite with max TLS version unpinned: \(noPinPassed ? "WORKS" : "DOES NOT WORK") — \(noPinDetail)\n")

    // --- Summary ---
    log("================ SUMMARY ================")
    for o in outcomes.all { log("\(o.passed ? "PASS" : "FAIL")  \(o.name)") }
    log("INFO  TLS1.3 PSK variant: \(tls13Passed ? "works" : "does not work")")
    log("INFO  PSK with max TLS version unpinned: \(noPinPassed ? "works" : "does not work")")
    let allPassed = outcomes.all.count == 2 && outcomes.all.allSatisfy(\.passed)
    log("OVERALL: \(allPassed ? "PASS" : "FAIL")")
    return allPassed ? 0 : 1
}

func serve(pskHex: String, flavor: TLSFlavor) async -> Int32 {
    guard let psk = Data(hexString: pskHex), psk.count == 32 else {
        log("--serve needs a 64-hex-char (32-byte) PSK"); return 2
    }
    do {
        let server = try Server(psk: psk, flavor: flavor)
        let port = try await server.start()
        defer { server.cancel() }
        log("PORT \(port)")
        log("[serve] waiting for one client (\(flavor.rawValue), identity \(pskIdentity))…")
        let result = try await withTimeout(300, "serve") { () -> RoleResult in
            guard let peer = await server.nextConnection() else { throw SpikeError.cancelled }
            defer { peer.cancel() }
            return try await runServerHalf(peer, handshakeTimeout: 30).0
        }
        log("\n==> PASS serve: TLS \(result.tls); \(result.notes.joined(separator: "; "))")
        return 0
    } catch {
        log("\n==> FAIL serve: \(error)")
        return 1
    }
}

let args = CommandLine.arguments
let status: Int32
if let i = args.firstIndex(of: "--serve"), i + 1 < args.count {
    status = await serve(pskHex: args[i + 1], flavor: args.contains("--tls13") ? .tls13PSK : .tls12PSK)
} else {
    status = await selfTest()
}
exit(status)
