// psk-spike-client: client half of the PSK spike as ONE self-contained file so it can be compiled
// for the iOS simulator with plain swiftc:
//
//   xcrun -sdk iphonesimulator swiftc -target arm64-apple-ios18.0-simulator -O \
//       -o .build/ios-client Sources/psk-spike-client/main.swift
//   xcrun simctl spawn <UDID> .build/ios-client 127.0.0.1 <port> <pskhex> [--tls13]
//
// It also builds as a normal SwiftPM executable on macOS (`swift run psk-spike-client ...`).

import Foundation
import Network
import Security
import CryptoKit

// MARK: - Framing

enum FrameType: UInt8 { case hello = 1, helloAck = 2, data = 4, digest = 5 }

struct FrameHeader {
    static let size = 8
    var version: UInt8 = 1
    var type: UInt8
    var reserved: UInt16 = 0
    var payloadLength: UInt32

    func encoded() -> Data {
        var d = Data(capacity: 8)
        d.append(version); d.append(type)
        d.appendBigEndian(reserved); d.appendBigEndian(payloadLength)
        return d
    }
    init(type: UInt8, payloadLength: UInt32) { self.type = type; self.payloadLength = payloadLength }
    init(decoding data: Data) throws {
        guard data.count == 8 else { throw ClientError.proto("header \(data.count) bytes") }
        let b = [UInt8](data)
        version = b[0]; type = b[1]
        reserved = UInt16(b[2]) << 8 | UInt16(b[3])
        payloadLength = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        guard version == 1, reserved == 0 else { throw ClientError.proto("bad version/reserved") }
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(self[startIndex + offset + i]) }
        return v
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    init?(hexString: String) {
        let chars = Array(hexString.lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            out.append(b); i += 2
        }
        self = out
    }
}

enum ClientError: Error, CustomStringConvertible {
    case failed(Error), waiting(Error), cancelled, timeout, shortRead(Int, Int), proto(String), verify(String)
    var description: String {
        switch self {
        case .failed(let e): return "connection failed: \(e)"
        case .waiting(let e): return "connection waiting: \(e)"
        case .cancelled: return "cancelled"
        case .timeout: return "timeout"
        case .shortRead(let e, let g): return "short read: expected \(e) got \(g)"
        case .proto(let s): return "protocol: \(s)"
        case .verify(let s): return "verify: \(s)"
        }
    }
}

// MARK: - TLS PSK options (identical to the server side)

func makeParameters(psk: Data, identity: String, tls13: Bool) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions
    let pskDD = psk.withUnsafeBytes { DispatchData(bytes: $0) }
    let idDD = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(sec, pskDD as __DispatchData, idDD as __DispatchData)
    if tls13 {
        sec_protocol_options_append_tls_ciphersuite(sec, .AES_128_GCM_SHA256)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
    } else {
        // TLS_PSK_WITH_AES_128_GCM_SHA256 = 0x00A8 (RFC 5487); not a named case of tls_ciphersuite_t.
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0x00A8)!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
    }
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWParameters(tls: tls, tcp: tcp)
}

// MARK: - Connection wrapper

final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { self.c = c }
    func resume(_ r: Result<T, Error>) {
        lock.lock(); let x = c; c = nil; lock.unlock()
        x?.resume(with: r)
    }
}

final class Client: @unchecked Sendable {
    let connection: NWConnection
    let queue = DispatchQueue(label: "psk-spike-client")
    init(connection: NWConnection) { self.connection = connection }

    func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once(cont)
            connection.stateUpdateHandler = { state in
                print("[client] state -> \(state)")
                switch state {
                case .ready: once.resume(.success(()))
                case .failed(let e): once.resume(.failure(ClientError.failed(e)))
                case .waiting(let e): once.resume(.failure(ClientError.waiting(e)))
                case .cancelled: once.resume(.failure(ClientError.cancelled))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { once.resume(.failure(ClientError.timeout)) }
        }
    }

    func send(type: FrameType, payload: Data) async throws {
        var frame = FrameHeader(type: type.rawValue, payloadLength: UInt32(payload.count)).encoded()
        frame.append(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { e in
                if let e { cont.resume(throwing: e) } else { cont.resume() }
            })
        }
    }

    func receiveExactly(_ n: Int) async throws -> Data {
        if n == 0 { return Data() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: n, maximumLength: n) { content, _, _, error in
                if let error { cont.resume(throwing: error); return }
                guard let content, content.count == n else { cont.resume(throwing: ClientError.shortRead(n, content?.count ?? 0)); return }
                cont.resume(returning: content)
            }
        }
    }

    func receiveFrame() async throws -> (FrameHeader, Data) {
        let h = try FrameHeader(decoding: try await receiveExactly(FrameHeader.size))
        return (h, try await receiveExactly(Int(h.payloadLength)))
    }

    func negotiated() -> String {
        guard let md = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return "n/a" }
        let v = sec_protocol_metadata_get_negotiated_tls_protocol_version(md.securityProtocolMetadata).rawValue
        let cs = sec_protocol_metadata_get_negotiated_tls_ciphersuite(md.securityProtocolMetadata).rawValue
        return String(format: "version=0x%04x ciphersuite=0x%04x", v, cs)
    }
}

// MARK: - Main

func run() async -> Int32 {
    let args = CommandLine.arguments
    guard args.count >= 4, let port = UInt16(args[2]), let psk = Data(hexString: args[3]), psk.count == 32 else {
        print("usage: psk-spike-client <host> <port> <pskhex-64-chars> [--tls13]")
        return 2
    }
    let host = args[1]
    let tls13 = args.contains("--tls13")
    #if targetEnvironment(simulator)
    print("[client] running in iOS simulator; ProcessInfo OS version \(ProcessInfo.processInfo.operatingSystemVersionString)")
    #else
    print("[client] running on \(ProcessInfo.processInfo.operatingSystemVersionString)")
    #endif
    let params = makeParameters(psk: psk, identity: "chauffeur-remote", tls13: tls13)
    let client = Client(connection: NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params))
    defer { client.connection.cancel() }
    do {
        try await client.start(timeout: 10)
        print("[client] negotiated TLS: \(client.negotiated())")

        try await client.send(type: .hello, payload: Data(#"{"hello":true}"#.utf8))
        let (ackH, ackP) = try await client.receiveFrame()
        guard ackH.type == FrameType.helloAck.rawValue else { throw ClientError.proto("expected type 2, got \(ackH.type)") }
        guard (try JSONSerialization.jsonObject(with: ackP) as? [String: Any])?["ok"] as? Bool == true else { throw ClientError.proto("bad ack") }
        print("[client] helloAck OK: \(String(decoding: ackP, as: UTF8.self))")

        var digest = Data()
        for expected in 0..<3 {
            let (h, p) = try await client.receiveFrame()
            guard h.type == FrameType.data.rawValue else { throw ClientError.proto("expected type 4, got \(h.type)") }
            guard p.count == 16 + 65536 else { throw ClientError.proto("data payload \(p.count) bytes") }
            let gen = p.readBigEndianUInt64(at: 0), seq = p.readBigEndianUInt64(at: 8)
            guard seq == UInt64(expected) else { throw ClientError.verify("expected seq \(expected) got \(seq)") }
            let hash = Data(SHA256.hash(data: p.subdata(in: 16..<p.count)))
            digest.appendBigEndian(seq); digest.append(hash)
            print("[client] data seq=\(seq) gen=\(gen) sha256=\(hash.hexString.prefix(16))…")
        }
        try await client.send(type: .digest, payload: digest)
        print("[client] sent digest; PASS")
        return 0
    } catch {
        print("[client] FAIL: \(error)")
        return 1
    }
}

exit(await run())
