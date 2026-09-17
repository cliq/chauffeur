import Foundation
import ChauffeurRemoteProtocol

/// The serialized, backpressured write path of one remote client connection.
/// `send` returns once the transport has taken the bytes, so a sink that awaits
/// it never buffers more than one frame ahead of the network.
public protocol RemoteConnectionHandle: AnyObject, Sendable {
    func send(_ data: Data) async throws
}

/// Delivers attachment output to an iPhone as `.output` frames. Output is held
/// until `releaseOutput(generation:)` so the client always reads the attach
/// response before the first terminal frame; closing sends `attachmentEnded`.
public final class RemoteFrameSink: TerminalOutputSink, @unchecked Sendable {
    private let handle: any RemoteConnectionHandle
    private let onClose: (@Sendable (AttachmentGeneration) -> Void)?
    private let gate = OutputGate()
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var generation: AttachmentGeneration = 0
    private var closed = false

    public init(handle: any RemoteConnectionHandle, holdOutput: Bool = true, onClose: (@Sendable (AttachmentGeneration) -> Void)? = nil) {
        self.handle = handle
        self.onClose = onClose
        if !holdOutput { gate.open() }
    }

    /// The generation the attachment was granted; output flows from here on.
    /// Calling it more than once is harmless.
    public func releaseOutput(generation: AttachmentGeneration) {
        lock.withLock { self.generation = generation }
        gate.open()
    }

    public var currentGeneration: AttachmentGeneration { lock.withLock { generation } }

    public func write(_ bytes: Data) async throws {
        await gate.wait()
        guard let payload = nextPayload(bytes) else { throw RemoteFrameSinkError.closed }
        try await handle.send(RemoteFraming.encode(RemoteFrame(type: .output, payload: payload.encoded())))
    }

    /// Stamps the next sequence number, or nil once the sink is closed.
    private func nextPayload(_ bytes: Data) -> TerminalFramePayload? {
        lock.withLock {
            guard !closed else { return nil }
            sequence += 1
            return TerminalFramePayload(generation: generation, sequence: sequence, bytes: bytes)
        }
    }

    /// Marks the sink closed; nil when it already was.
    private func markClosed() -> AttachmentGeneration? {
        lock.withLock {
            guard !closed else { return nil }
            closed = true
            return generation
        }
    }

    public func close(reason: AttachmentEndReason, message: String?) async {
        await gate.wait()
        guard let generation = markClosed() else { return }
        let mapped = ChauffeurRemoteProtocol.AttachmentEndReason(rawValue: reason.rawValue) ?? .transportClosed
        let event = RemoteEvent.attachmentEnded(generation: generation, reason: mapped, message: message)
        if let payload = try? RemoteJSON.encode(event) {
            try? await handle.send(RemoteFraming.encode(RemoteFrame(type: .event, payload: payload)))
        }
        onClose?(generation)
    }
}

enum RemoteFrameSinkError: Error {
    case closed
}
