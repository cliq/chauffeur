import Foundation
import Network

let dataFrameCount = 3
let dataBodySize = 64 * 1024
let dataGeneration: UInt64 = 1

struct RoleResult: Sendable {
    var tls: String
    var notes: [String]
}

/// Server half of the positive test, run on one accepted connection.
/// Returns the SHA-256 of each 64 KiB body it sent, so an in-process caller can cross-check the client.
func runServerHalf(_ peer: Peer, handshakeTimeout: TimeInterval = 5) async throws -> (RoleResult, [Data]) {
    try await peer.start(timeout: handshakeTimeout)
    let tls = peer.connection.negotiatedTLS()
    log("[\(peer.label)] negotiated TLS: \(tls.map(String.init(describing:)) ?? "n/a")")
    var notes: [String] = []

    // 1. hello
    let hello = try await peer.receiveFrame()
    guard hello.header.type == FrameType.hello.rawValue else { throw SpikeError.protocolViolation("expected hello(1), got type \(hello.header.type)") }
    let helloJSON = try JSONSerialization.jsonObject(with: hello.payload) as? [String: Any]
    guard helloJSON?["hello"] as? Bool == true else { throw SpikeError.protocolViolation("hello payload was \(String(decoding: hello.payload, as: UTF8.self))") }
    log("[\(peer.label)] got hello: \(String(decoding: hello.payload, as: UTF8.self))")
    notes.append("received hello frame")

    // 2. ack
    try await peer.send(type: .helloAck, payload: Data(#"{"ok":true}"#.utf8))
    notes.append("sent helloAck")

    // 3. three data frames, each awaited (.contentProcessed) before the next
    var hashes: [Data] = []
    for seq in 0..<dataFrameCount {
        let body = Data.random(count: dataBodySize)
        var payload = DataSubheader(generation: dataGeneration, sequence: UInt64(seq)).encoded()
        payload.append(body)
        let t0 = Date()
        try await peer.send(type: .data, payload: payload)
        hashes.append(body.sha256)
        log("[\(peer.label)] sent data seq=\(seq) (\(payload.count) bytes) in \(String(format: "%.1f", Date().timeIntervalSince(t0) * 1000)) ms, sha256=\(hashes[seq].hexString.prefix(16))…")
    }
    notes.append("sent \(dataFrameCount) x \(dataBodySize) B data frames")

    // 4. digest from client
    let digest = try await peer.receiveFrame()
    guard digest.header.type == FrameType.digest.rawValue else { throw SpikeError.protocolViolation("expected digest(5), got type \(digest.header.type)") }
    guard digest.payload.count == dataFrameCount * 40 else { throw SpikeError.protocolViolation("digest payload is \(digest.payload.count) bytes") }
    for i in 0..<dataFrameCount {
        let seq = digest.payload.readBigEndianUInt64(at: i * 40)
        let hash = digest.payload.subdata(in: (i * 40 + 8)..<(i * 40 + 40))
        guard seq == UInt64(i) else { throw SpikeError.verification("digest \(i) reports sequence \(seq)") }
        guard hash == hashes[i] else { throw SpikeError.verification("client hash for seq \(i) differs from what server sent") }
    }
    log("[\(peer.label)] client digest matches all \(dataFrameCount) frames")
    notes.append("client digest verified: ordering + SHA-256 match")
    return (RoleResult(tls: tls.map(String.init(describing:)) ?? "n/a", notes: notes), hashes)
}

/// Client half of the positive test.
func runClientHalf(_ peer: Peer, handshakeTimeout: TimeInterval = 5) async throws -> (RoleResult, [Data]) {
    try await peer.start(timeout: handshakeTimeout)
    let tls = peer.connection.negotiatedTLS()
    log("[\(peer.label)] negotiated TLS: \(tls.map(String.init(describing:)) ?? "n/a")")
    var notes: [String] = []

    try await peer.send(type: .hello, payload: Data(#"{"hello":true}"#.utf8))
    let ack = try await peer.receiveFrame()
    guard ack.header.type == FrameType.helloAck.rawValue else { throw SpikeError.protocolViolation("expected helloAck(2), got type \(ack.header.type)") }
    let ackJSON = try JSONSerialization.jsonObject(with: ack.payload) as? [String: Any]
    guard ackJSON?["ok"] as? Bool == true else { throw SpikeError.protocolViolation("ack payload was \(String(decoding: ack.payload, as: UTF8.self))") }
    log("[\(peer.label)] got ack: \(String(decoding: ack.payload, as: UTF8.self))")
    notes.append("hello/helloAck round trip OK")

    var hashes: [Data] = []
    var digest = Data()
    for expectedSeq in 0..<dataFrameCount {
        let frame = try await peer.receiveFrame()
        guard frame.header.type == FrameType.data.rawValue else { throw SpikeError.protocolViolation("expected data(4), got type \(frame.header.type)") }
        guard frame.payload.count == DataSubheader.size + dataBodySize else { throw SpikeError.protocolViolation("data payload is \(frame.payload.count) bytes") }
        let sub = try DataSubheader(decoding: frame.payload)
        guard sub.generation == dataGeneration else { throw SpikeError.verification("generation \(sub.generation)") }
        guard sub.sequence == UInt64(expectedSeq) else { throw SpikeError.verification("out of order: expected seq \(expectedSeq), got \(sub.sequence)") }
        let body = frame.payload.subdata(in: DataSubheader.size..<frame.payload.count)
        let hash = body.sha256
        hashes.append(hash)
        digest.appendBigEndian(sub.sequence)
        digest.append(hash)
        log("[\(peer.label)] got data seq=\(sub.sequence) gen=\(sub.generation) body=\(body.count) B sha256=\(hash.hexString.prefix(16))…")
    }
    notes.append("received \(dataFrameCount) data frames in order")
    try await peer.send(type: .digest, payload: digest)
    notes.append("sent digest")
    return (RoleResult(tls: tls.map(String.init(describing:)) ?? "n/a", notes: notes), hashes)
}

func makeClient(port: UInt16, psk: Data, flavor: TLSFlavor, label: String, host: String = "127.0.0.1") -> Peer {
    let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: makeParameters(psk: psk, flavor: flavor))
    return Peer(connection: connection, label: label)
}
