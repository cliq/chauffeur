import Foundation

/// Binary frame types exchanged between the Mac runtime and the iPhone client.
public enum RemoteFrameType: UInt8, Sendable {
    case request = 1
    case response = 2
    case event = 3
    case output = 4
    case input = 5
    case ping = 6
    case pong = 7
}

/// A single decoded frame: its type and raw payload bytes.
public struct RemoteFrame: Equatable, Sendable {
    public var type: RemoteFrameType
    public var payload: Data

    public init(type: RemoteFrameType, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

public enum RemoteFramingError: Error, Equatable, Sendable {
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case reservedBitsSet(UInt16)
    case payloadTooLarge(UInt32)
    case truncatedTerminalPayload
}

/// Binary framing shared by both ends of the remote protocol.
///
/// Wire format (big-endian, 8-byte header):
/// `version(1) | type(1) | reserved(2) | payloadLength(4) | payload...`
public enum RemoteFraming {
    public static let version: UInt8 = 1
    public static let headerSize = 8
    public static let maxPayloadBytes: UInt32 = 4 * 1024 * 1024
    public static let maxTerminalChunkBytes = 64 * 1024

    public static func encode(_ frame: RemoteFrame) -> Data {
        var data = Data(capacity: headerSize + frame.payload.count)
        data.append(version)
        data.append(frame.type.rawValue)
        data.append(contentsOf: bigEndianBytes(UInt16(0)))
        data.append(contentsOf: bigEndianBytes(UInt32(frame.payload.count)))
        data.append(frame.payload)
        return data
    }

    fileprivate static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    fileprivate static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }

    fileprivate static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (56 - $0 * 8)) }
    }
}

/// Incremental decoder: feed arbitrary byte chunks, get complete frames back.
///
/// Throws on protocol violations; after a throw the decoder is unusable and will
/// keep throwing the same error for any further input.
public struct RemoteFrameDecoder: Sendable {
    private var buffer = Data()
    private var pendingType: RemoteFrameType?
    private var pendingPayloadLength: Int?
    private var poisonedError: RemoteFramingError?

    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) throws -> [RemoteFrame] {
        if let poisonedError {
            throw poisonedError
        }
        do {
            return try decode(appending: data)
        } catch let error as RemoteFramingError {
            poisonedError = error
            throw error
        }
    }

    private mutating func decode(appending data: Data) throws -> [RemoteFrame] {
        buffer.append(data)
        var frames: [RemoteFrame] = []

        while true {
            if pendingType == nil {
                guard buffer.count >= RemoteFraming.headerSize else { break }
                let headerBytes = [UInt8](buffer.prefix(RemoteFraming.headerSize))

                let version = headerBytes[0]
                guard version == RemoteFraming.version else {
                    throw RemoteFramingError.unsupportedVersion(version)
                }

                guard let type = RemoteFrameType(rawValue: headerBytes[1]) else {
                    throw RemoteFramingError.unknownType(headerBytes[1])
                }

                let reserved = UInt16(headerBytes[2]) << 8 | UInt16(headerBytes[3])
                guard reserved == 0 else {
                    throw RemoteFramingError.reservedBitsSet(reserved)
                }

                let length = UInt32(headerBytes[4]) << 24
                    | UInt32(headerBytes[5]) << 16
                    | UInt32(headerBytes[6]) << 8
                    | UInt32(headerBytes[7])
                guard length <= RemoteFraming.maxPayloadBytes else {
                    throw RemoteFramingError.payloadTooLarge(length)
                }

                buffer.removeFirst(RemoteFraming.headerSize)
                pendingType = type
                pendingPayloadLength = Int(length)
            }

            guard let type = pendingType, let payloadLength = pendingPayloadLength else { break }
            guard buffer.count >= payloadLength else { break }

            let payload = Data(buffer.prefix(payloadLength))
            buffer.removeFirst(payloadLength)
            frames.append(RemoteFrame(type: type, payload: payload))
            pendingType = nil
            pendingPayloadLength = nil
        }

        return frames
    }
}

/// Payload layout for `.output` and `.input` frames:
/// `generation(8, BE) | sequence(8, BE) | raw terminal bytes`.
public struct TerminalFramePayload: Equatable, Sendable {
    public var generation: UInt64
    public var sequence: UInt64
    public var bytes: Data

    public init(generation: UInt64, sequence: UInt64, bytes: Data) {
        self.generation = generation
        self.sequence = sequence
        self.bytes = bytes
    }

    public func encoded() -> Data {
        var data = Data(capacity: 16 + bytes.count)
        data.append(contentsOf: RemoteFraming.bigEndianBytes(generation))
        data.append(contentsOf: RemoteFraming.bigEndianBytes(sequence))
        data.append(bytes)
        return data
    }

    public init(decoding data: Data) throws {
        guard data.count >= 16 else {
            throw RemoteFramingError.truncatedTerminalPayload
        }
        let headerBytes = [UInt8](data.prefix(16))

        var generation: UInt64 = 0
        for index in 0..<8 {
            generation = (generation << 8) | UInt64(headerBytes[index])
        }

        var sequence: UInt64 = 0
        for index in 8..<16 {
            sequence = (sequence << 8) | UInt64(headerBytes[index])
        }

        self.generation = generation
        self.sequence = sequence
        self.bytes = Data(data.dropFirst(16))
    }
}
