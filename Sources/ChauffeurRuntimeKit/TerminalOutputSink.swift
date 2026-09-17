import Foundation
import ChauffeurCore

/// Why an attachment stopped delivering output to its client.
public enum AttachmentEndReason: String, Codable, Sendable {
    case controlLost, clientDetached, sessionEnded, slowConsumer, transportClosed, revoked
}

/// Server-global, monotonic identity of one attachment. A stale generation
/// can never act on the attachment that replaced it.
public typealias AttachmentGeneration = UInt64

/// Transport-independent destination for attachment output. Implementations
/// must apply backpressure in `write` (suspend until the bytes are handed to
/// the transport) instead of buffering unboundedly.
public protocol TerminalOutputSink: AnyObject, Sendable {
    func write(_ bytes: Data) async throws
    func close(reason: AttachmentEndReason, message: String?) async
}

/// Delivers attachment output to the local Unix-socket connection of the
/// desktop app. Output can be held back until the attach acknowledgement has
/// been written so the client never sees a terminal frame before its reply.
public final class LocalSocketSink: TerminalOutputSink {
    private let connection: SocketConnection
    private let gate = OutputGate()
    public init(connection: SocketConnection, holdOutput: Bool = false) {
        self.connection = connection
        if !holdOutput { gate.open() }
    }
    /// Lets held output flow. Calling it more than once is harmless.
    public func releaseOutput() { gate.open() }
    public func write(_ bytes: Data) async throws {
        await gate.wait()
        try await connection.sendAsync(TerminalPacket(kind: "output", bytes: bytes))
    }
    public func close(reason: AttachmentEndReason, message: String?) async {
        await gate.wait()
        switch reason {
        case .controlLost:
            try? await connection.sendAsync(TerminalPacket(kind: "controlLost", message: message ?? "Another client took control of this terminal"))
        case .clientDetached:
            break
        case .sessionEnded, .slowConsumer, .transportClosed, .revoked:
            try? await connection.sendAsync(TerminalPacket(kind: "error", message: message ?? "Terminal detached"))
        }
        connection.close()
    }
}

/// One-shot latch that suspends callers until it is opened.
private final class OutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() {
        lock.lock()
        opened = true
        let pending = waiters; waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Bounded, ordered queue between the blocking PTY reader thread and an async
/// drain task that writes to the sink. Adjacent chunks are coalesced up to
/// 64 KiB per write to reduce frame count without reordering bytes.
final class AttachmentPump: @unchecked Sendable {
    let generation: AttachmentGeneration
    private let sink: any TerminalOutputSink
    private let maxQueuedBytes: Int
    private let maxQueuedChunks: Int
    private let onEnd: @Sendable (AttachmentGeneration) -> Void
    private let lock = NSLock()
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var revoked = false
    private var finished = false
    /// The pump closed, or decided never to close, the sink: exactly one of
    /// `revoke`, overflow, transport failure or EOF wins.
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var drain: Task<Void, Never>?
    private static let coalesceLimit = 64 * 1024
    /// `onEnd` fires once, off the caller's thread, when the pump ends the
    /// attachment by itself: the queue overflowed (a slow consumer), the sink
    /// rejected a write (transport gone), or the reader reached EOF. It does not
    /// fire after `revoke()`; the caller already owns that teardown.
    init(generation: AttachmentGeneration, sink: any TerminalOutputSink, maxQueuedBytes: Int = 1 << 20, maxQueuedChunks: Int = 256, onEnd: @escaping @Sendable (AttachmentGeneration) -> Void) {
        self.generation = generation; self.sink = sink
        self.maxQueuedBytes = maxQueuedBytes; self.maxQueuedChunks = maxQueuedChunks
        self.onEnd = onEnd
    }
    var isRevoked: Bool { lock.lock(); defer { lock.unlock() }; return revoked }
    /// Starts the drain task. Chunks enqueued before this call are kept.
    func start() {
        lock.lock()
        guard drain == nil else { lock.unlock(); return }
        drain = Task { [self] in await self.run() }
        lock.unlock()
    }
    /// Called from the reader thread. Dropped once revoked; an overflow revokes
    /// the pump and closes the sink as a slow consumer.
    func enqueue(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        if revoked { lock.unlock(); return }
        if queuedBytes + chunk.count > maxQueuedBytes || queue.count + 1 > maxQueuedChunks {
            revoked = true; ended = true; queue = []; queuedBytes = 0
            let pending = waiter; waiter = nil
            lock.unlock()
            pending?.resume()
            onEnd(generation)
            let sink = self.sink
            Task { await sink.close(reason: .slowConsumer, message: "Terminal output was not consumed quickly enough") }
            return
        }
        queue.append(chunk); queuedBytes += chunk.count
        let pending = waiter; waiter = nil
        lock.unlock()
        pending?.resume()
    }
    /// Reader hit EOF: remaining output is drained, then the sink is closed
    /// with `.sessionEnded` unless the pump was revoked first.
    func finish() {
        lock.lock()
        finished = true
        let pending = waiter; waiter = nil
        lock.unlock()
        pending?.resume()
    }
    /// The drain stops before its next write and never closes the sink; the
    /// caller closes it with the reason it knows.
    func revoke() {
        lock.lock()
        revoked = true; ended = true; queue = []; queuedBytes = 0
        let pending = waiter; waiter = nil
        lock.unlock()
        pending?.resume()
    }
    private enum Step { case write(Data), finish, stop }
    private func run() async {
        while true {
            switch await next() {
            case .stop: return
            case .finish:
                guard claimEnd() else { return }
                await sink.close(reason: .sessionEnded, message: "Terminal session ended")
                onEnd(generation)
                return
            case .write(let data):
                do { try await sink.write(data) }
                catch {
                    guard claimEnd() else { return }
                    await sink.close(reason: .transportClosed, message: nil)
                    onEnd(generation)
                    return
                }
            }
        }
    }
    /// Marks the pump ended and revoked; false when another path already did.
    private func claimEnd() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return false }
        ended = true; revoked = true; queue = []; queuedBytes = 0
        return true
    }
    private func next() async -> Step {
        while true {
            if let step = poll() { return step }
            await withCheckedContinuation { continuation in
                lock.lock()
                // Re-check under the lock so a wake-up between poll and here
                // is never lost.
                if revoked || !queue.isEmpty || finished { lock.unlock(); continuation.resume(); return }
                waiter = continuation
                lock.unlock()
            }
        }
    }
    /// The next drain step, or nil when the drain has to wait for more output.
    private func poll() -> Step? {
        lock.lock(); defer { lock.unlock() }
        if revoked { return .stop }
        if !queue.isEmpty {
            var batch = queue.removeFirst()
            while let following = queue.first, batch.count + following.count <= Self.coalesceLimit {
                batch.append(following); queue.removeFirst()
            }
            queuedBytes -= batch.count
            return .write(batch)
        }
        if finished { return .finish }
        return nil
    }
}
