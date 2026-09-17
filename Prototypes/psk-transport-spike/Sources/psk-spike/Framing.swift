import Foundation
import CryptoKit

/// Frame types used by the spike.
enum FrameType: UInt8 {
    case hello = 1      // client -> server, JSON {"hello":true}
    case helloAck = 2   // server -> client, JSON {"ok":true}
    case data = 4       // server -> client, 16-byte subheader (generation UInt64, sequence UInt64) + 64 KiB random
    case digest = 5     // client -> server, N x (sequence UInt64 BE + 32-byte SHA-256) so the server can verify
}

/// 8-byte big-endian header: version UInt8 = 1, type UInt8, reserved UInt16 = 0, payloadLength UInt32.
struct FrameHeader: Equatable {
    static let size = 8
    static let currentVersion: UInt8 = 1

    var version: UInt8 = FrameHeader.currentVersion
    var type: UInt8
    var reserved: UInt16 = 0
    var payloadLength: UInt32

    func encoded() -> Data {
        var d = Data(capacity: FrameHeader.size)
        d.append(version)
        d.append(type)
        d.appendBigEndian(reserved)
        d.appendBigEndian(payloadLength)
        return d
    }

    init(type: UInt8, payloadLength: UInt32) {
        self.type = type
        self.payloadLength = payloadLength
    }

    init(decoding data: Data) throws {
        guard data.count == FrameHeader.size else { throw SpikeError.protocolViolation("header is \(data.count) bytes, expected 8") }
        let b = [UInt8](data)
        version = b[0]
        type = b[1]
        reserved = UInt16(b[2]) << 8 | UInt16(b[3])
        payloadLength = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        guard version == FrameHeader.currentVersion else { throw SpikeError.protocolViolation("unsupported frame version \(version)") }
        guard reserved == 0 else { throw SpikeError.protocolViolation("reserved field is \(reserved), expected 0") }
    }
}

/// 16-byte subheader that precedes the random bytes in a `.data` frame.
struct DataSubheader: Equatable {
    static let size = 16
    var generation: UInt64
    var sequence: UInt64

    func encoded() -> Data {
        var d = Data(capacity: DataSubheader.size)
        d.appendBigEndian(generation)
        d.appendBigEndian(sequence)
        return d
    }

    init(generation: UInt64, sequence: UInt64) {
        self.generation = generation
        self.sequence = sequence
    }

    init(decoding data: Data) throws {
        guard data.count >= DataSubheader.size else { throw SpikeError.protocolViolation("data payload shorter than subheader") }
        generation = data.readBigEndianUInt64(at: 0)
        sequence = data.readBigEndianUInt64(at: 8)
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
            out.append(b)
            i += 2
        }
        self = out
    }

    static func random(count: Int) -> Data {
        var d = Data(count: count)
        let status = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return d
    }

    var sha256: Data { Data(SHA256.hash(data: self)) }
}

enum SpikeError: Error, CustomStringConvertible {
    case timeout(String)
    case connectionFailed(Error)
    case connectionWaiting(Error)
    case cancelled
    case shortRead(expected: Int, got: Int)
    case protocolViolation(String)
    case verification(String)

    var description: String {
        switch self {
        case .timeout(let what): return "timeout: \(what)"
        case .connectionFailed(let e): return "connection failed: \(e)"
        case .connectionWaiting(let e): return "connection waiting: \(e)"
        case .cancelled: return "connection cancelled"
        case .shortRead(let expected, let got): return "short read: expected \(expected) bytes, got \(got)"
        case .protocolViolation(let s): return "protocol violation: \(s)"
        case .verification(let s): return "verification failed: \(s)"
        }
    }
}
