import Foundation
import Testing
@testable import ChauffeurRemoteProtocol

struct FramingTests {

    @Test func headerLayoutBytes() {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let frame = RemoteFrame(type: .request, payload: payload)
        let encoded = RemoteFraming.encode(frame)

        let expected: [UInt8] = [
            1, // version
            1, // type = .request
            0, 0, // reserved
            0, 0, 0, 3, // payload length = 3
            0xAA, 0xBB, 0xCC
        ]
        #expect([UInt8](encoded) == expected)
    }

    @Test(arguments: [
        RemoteFrameType.request,
        .response,
        .event,
        .output,
        .input,
        .ping,
        .pong
    ])
    func roundTripEachFrameType(type: RemoteFrameType) throws {
        let payload = Data("hello-\(type.rawValue)".utf8)
        let frame = RemoteFrame(type: type, payload: payload)
        let encoded = RemoteFraming.encode(frame)

        var decoder = RemoteFrameDecoder()
        let frames = try decoder.append(encoded)
        #expect(frames == [frame])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func incrementalDecodingAtEverySplitPoint() throws {
        let first = RemoteFrame(type: .request, payload: Data("first-payload".utf8))
        let second = RemoteFrame(type: .response, payload: Data("second-one".utf8))
        let combined = RemoteFraming.encode(first) + RemoteFraming.encode(second)

        for splitPoint in 0...combined.count {
            var decoder = RemoteFrameDecoder()
            let firstChunk = combined.prefix(splitPoint)
            let secondChunk = combined.suffix(from: combined.startIndex + splitPoint)

            var frames = try decoder.append(Data(firstChunk))
            frames += try decoder.append(Data(secondChunk))

            #expect(frames == [first, second], "failed at split point \(splitPoint)")
            #expect(decoder.bufferedByteCount == 0, "failed at split point \(splitPoint)")
        }
    }

    @Test func threeFramesInOneChunkDecodeToThree() throws {
        let frames = [
            RemoteFrame(type: .ping, payload: Data()),
            RemoteFrame(type: .output, payload: Data("chunk".utf8)),
            RemoteFrame(type: .pong, payload: Data([1, 2, 3]))
        ]
        let combined = frames.reduce(into: Data()) { $0 += RemoteFraming.encode($1) }

        var decoder = RemoteFrameDecoder()
        let decoded = try decoder.append(combined)
        #expect(decoded == frames)
    }

    @Test func oversizePayloadLengthRejectedWithoutPayloadBytes() throws {
        var header = Data([RemoteFraming.version, RemoteFrameType.request.rawValue, 0, 0])
        let oversizeLength = RemoteFraming.maxPayloadBytes + 1
        header.append(contentsOf: [
            UInt8(truncatingIfNeeded: oversizeLength >> 24),
            UInt8(truncatingIfNeeded: oversizeLength >> 16),
            UInt8(truncatingIfNeeded: oversizeLength >> 8),
            UInt8(truncatingIfNeeded: oversizeLength)
        ])

        var decoder = RemoteFrameDecoder()
        #expect(throws: RemoteFramingError.payloadTooLarge(oversizeLength)) {
            _ = try decoder.append(header)
        }
    }

    @Test func wrongVersionRejected() throws {
        let header = Data([0xFF, RemoteFrameType.request.rawValue, 0, 0, 0, 0, 0, 0])
        var decoder = RemoteFrameDecoder()
        #expect(throws: RemoteFramingError.unsupportedVersion(0xFF)) {
            _ = try decoder.append(header)
        }
    }

    @Test func reservedBitsRejected() throws {
        let header = Data([RemoteFraming.version, RemoteFrameType.request.rawValue, 0x00, 0x01, 0, 0, 0, 0])
        var decoder = RemoteFrameDecoder()
        #expect(throws: RemoteFramingError.reservedBitsSet(1)) {
            _ = try decoder.append(header)
        }
    }

    @Test func unknownTypeRejected() throws {
        let header = Data([RemoteFraming.version, 0xEE, 0, 0, 0, 0, 0, 0])
        var decoder = RemoteFrameDecoder()
        #expect(throws: RemoteFramingError.unknownType(0xEE)) {
            _ = try decoder.append(header)
        }
    }

    @Test func decoderIsUnusableAfterThrow() throws {
        let header = Data([0xFF, RemoteFrameType.request.rawValue, 0, 0, 0, 0, 0, 0])
        var decoder = RemoteFrameDecoder()
        #expect(throws: RemoteFramingError.unsupportedVersion(0xFF)) {
            _ = try decoder.append(header)
        }
        #expect(throws: RemoteFramingError.unsupportedVersion(0xFF)) {
            _ = try decoder.append(Data())
        }
    }

    @Test func terminalFramePayloadRoundTrip() throws {
        let payload = TerminalFramePayload(generation: 42, sequence: 7, bytes: Data("terminal-bytes".utf8))
        let decoded = try TerminalFramePayload(decoding: payload.encoded())
        #expect(decoded == payload)
    }

    @Test func terminalFramePayloadTruncationError() {
        let tooShort = Data(repeating: 0, count: 15)
        #expect(throws: RemoteFramingError.truncatedTerminalPayload) {
            _ = try TerminalFramePayload(decoding: tooShort)
        }
    }
}
