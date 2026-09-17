import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

/// In-memory sink that records every write and close. `block()` makes writes
/// suspend until `release()` so tests can pile output up behind a slow client.
actor RecordingSink: TerminalOutputSink {
    struct Closure: Equatable { let reason: AttachmentEndReason; let message: String? }
    private(set) var writes: [Data] = []
    private(set) var closes: [Closure] = []
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var bytes: Data { writes.reduce(into: Data()) { $0.append($1) } }
    var text: String { String(decoding: bytes, as: UTF8.self) }
    func write(_ bytes: Data) async throws {
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        writes.append(bytes)
    }
    func close(reason: AttachmentEndReason, message: String?) async { closes.append(Closure(reason: reason, message: message)) }
    func block() { blocked = true }
    func release() { blocked = false; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private func eventually(_ condition: @Sendable () async throws -> Bool) async throws {
    for _ in 0..<500 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw ChauffeurError("test_timeout", "Condition was not reached in time")
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AttachmentGeneration] = []
    func record(_ value: AttachmentGeneration) { lock.lock(); values.append(value); lock.unlock() }
    var recorded: [AttachmentGeneration] { lock.lock(); defer { lock.unlock() }; return values }
}

struct AttachmentPumpTests {
    @Test func drainsInOrderAndCoalescesAdjacentChunks() async throws {
        let sink = RecordingSink(), ended = Counter()
        let pump = AttachmentPump(generation: 7, sink: sink) { ended.record($0) }
        await sink.block()
        pump.start()
        var expected = Data()
        for index in 0..<100 {
            let chunk = Data(String(format: "chunk-%03d|", index).utf8) + Data(repeating: UInt8(index), count: 1000)
            expected.append(chunk); pump.enqueue(chunk)
        }
        // One write may already be in flight holding a single chunk; the rest
        // (about 99 KiB) fits into two coalesced writes at most.
        try await eventually { await sink.writes.count <= 1 }
        await sink.release()
        pump.finish()
        try await eventually { await sink.closes == [.init(reason: .sessionEnded, message: "Terminal session ended")] }
        #expect(await sink.bytes == expected)
        #expect(await sink.writes.count <= 3)
        #expect(ended.recorded == [7])
    }

    @Test func revokeStopsDeliveryWithoutClosingTheSink() async throws {
        let sink = RecordingSink(), ended = Counter()
        let pump = AttachmentPump(generation: 3, sink: sink) { ended.record($0) }
        await sink.block()
        pump.start()
        for index in 0..<10 { pump.enqueue(Data("queued-\(index) ".utf8)) }
        try await eventually { await sink.writes.count <= 1 }
        pump.revoke()
        #expect(pump.isRevoked)
        await sink.release()
        pump.enqueue(Data("late".utf8)); pump.finish()
        try await Task.sleep(for: .milliseconds(200))
        // At most the write already in flight when control was revoked lands.
        #expect(await sink.writes.count <= 1)
        #expect(await !sink.text.contains("late"))
        #expect(await sink.closes.isEmpty)
        #expect(ended.recorded.isEmpty)
    }

    @Test func overflowClosesAsSlowConsumerExactlyOnce() async throws {
        let sink = RecordingSink(), ended = Counter()
        let pump = AttachmentPump(generation: 11, sink: sink, maxQueuedBytes: 1 << 20, maxQueuedChunks: 4) { ended.record($0) }
        await sink.block()
        pump.start()
        for index in 0..<20 { pump.enqueue(Data("overflow-\(index)".utf8)) }
        try await eventually { await sink.closes.count == 1 }
        #expect(await sink.closes.first?.reason == .slowConsumer)
        #expect(pump.isRevoked)
        #expect(ended.recorded == [11])
        await sink.release()
        pump.finish(); pump.enqueue(Data("after".utf8))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await sink.closes.count == 1)
        #expect(ended.recorded == [11])
        #expect(await !sink.text.contains("after"))
    }

    @Test func overflowByBytesAlsoRevokes() async throws {
        let sink = RecordingSink(), ended = Counter()
        let pump = AttachmentPump(generation: 12, sink: sink, maxQueuedBytes: 100, maxQueuedChunks: 256) { ended.record($0) }
        await sink.block()
        pump.start()
        for _ in 0..<5 { pump.enqueue(Data(repeating: 0x41, count: 40)) }
        try await eventually { await sink.closes == [.init(reason: .slowConsumer, message: "Terminal output was not consumed quickly enough")] }
        #expect(ended.recorded == [12])
        await sink.release()
    }

    @Test func finishDrainsRemainingOutputThenClosesAsSessionEnded() async throws {
        let sink = RecordingSink(), ended = Counter()
        let pump = AttachmentPump(generation: 5, sink: sink) { ended.record($0) }
        pump.enqueue(Data("one ".utf8)); pump.enqueue(Data("two ".utf8)); pump.enqueue(Data("three".utf8))
        pump.finish()
        pump.start()
        try await eventually { await sink.closes.count == 1 }
        #expect(await sink.text == "one two three")
        #expect(await sink.closes == [.init(reason: .sessionEnded, message: "Terminal session ended")])
        #expect(ended.recorded == [5])
        #expect(pump.isRevoked)
    }

    @Test func transportFailureClosesOnceAndEndsTheAttachment() async throws {
        final class FailingSink: TerminalOutputSink {
            let closes = Counter()
            func write(_ bytes: Data) async throws { throw ChauffeurError("connection_closed", "gone") }
            func close(reason: AttachmentEndReason, message: String?) async { closes.record(reason == .transportClosed ? 1 : 0) }
        }
        let sink = FailingSink(), ended = Counter()
        let pump = AttachmentPump(generation: 9, sink: sink) { ended.record($0) }
        pump.start()
        pump.enqueue(Data("x".utf8))
        try await eventually { ended.recorded == [9] }
        pump.enqueue(Data("y".utf8)); pump.finish()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sink.closes.recorded == [1])
        #expect(ended.recorded == [9])
    }
}

struct AttachmentGenerationTests {
    @Test func secondAttachmentWithoutTakeControlIsRefused() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let session = try await fixture.runtime.launch(fixture.request)
        let first = RecordingSink(), second = RecordingSink()
        let generation = try await fixture.runtime.terminals.attach(sessionID: session.id, sink: first, cols: 100, rows: 30, takeControl: false)
        var code: String?
        do { _ = try await fixture.runtime.terminals.attach(sessionID: session.id, sink: second, cols: 100, rows: 30, takeControl: false) }
        catch let error as ChauffeurError { code = error.code }
        #expect(code == "terminal_busy")
        #expect(await fixture.runtime.terminals.currentGeneration(sessionID: session.id) == generation)
        #expect(await second.closes.isEmpty)
        #expect(await first.closes.isEmpty)
        await fixture.runtime.terminals.detach(sessionID: session.id, generation: generation)
        try await eventually { await first.closes == [.init(reason: .clientDetached, message: nil)] }
        #expect(await fixture.runtime.terminals.currentGeneration(sessionID: session.id) == nil)
        _ = try await fixture.stop()
    }

    @Test func takingControlRevokesThePreviousClient() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        try Data("READY-MARKER".utf8).write(to: fixture.path("unicode-output"))
        let session = try await fixture.runtime.launch(fixture.request)
        try await fixture.wait { try await fixture.runtime.terminals.capture(sessionID: session.id, lines: 100).screen.contains("READY-MARKER") }
        let first = RecordingSink(), second = RecordingSink()
        let terminals = await fixture.runtime.terminals
        let old = try await terminals.attach(sessionID: session.id, sink: first, cols: 100, rows: 30, takeControl: false)
        try await eventually { await first.text.contains("READY-MARKER") }
        let new = try await terminals.attach(sessionID: session.id, sink: second, cols: 100, rows: 30, takeControl: true)
        #expect(new > old)
        try await eventually { await first.closes.count == 1 }
        #expect(await first.closes.first == .init(reason: .controlLost, message: "Another client took control of this terminal"))
        #expect(await terminals.currentGeneration(sessionID: session.id) == new)
        // The revoked generation cannot act on the terminal any more...
        var inputCode: String?, resizeCode: String?
        do { try await terminals.input(sessionID: session.id, generation: old, bytes: Data("stale".utf8)) } catch let error as ChauffeurError { inputCode = error.code }
        do { try await terminals.resize(sessionID: session.id, generation: old, cols: 90, rows: 25) } catch let error as ChauffeurError { resizeCode = error.code }
        #expect(inputCode == "attachment_revoked")
        #expect(resizeCode == "attachment_revoked")
        // ...and its teardown leaves the new attachment untouched.
        await terminals.detach(sessionID: session.id, generation: old)
        #expect(await terminals.currentGeneration(sessionID: session.id) == new)
        #expect(await second.closes.isEmpty)
        // Output stops at the old sink once it has been closed: generate fresh
        // output through the new generation and confirm only the new sink sees it.
        try await eventually { await second.text.contains("READY-MARKER") }
        try await Task.sleep(for: .milliseconds(200))
        let staleWrites = await first.writes.count
        try await terminals.input(sessionID: session.id, generation: new, bytes: Data("typed-through-new-generation".utf8))
        try await eventually { await second.text.contains("typed-through-new-generation") }
        try await fixture.wait { try await terminals.capture(sessionID: session.id, lines: 100).screen.contains("typed-through-new-generation") }
        #expect(await first.writes.count == staleWrites)
        #expect(await !first.text.contains("typed-through-new-generation"))
        try await terminals.resize(sessionID: session.id, generation: new, cols: 110, rows: 35)
        await terminals.detach(sessionID: session.id, generation: new)
        #expect(await terminals.currentGeneration(sessionID: session.id) == nil)
        _ = try await fixture.stop()
    }

    @Test func generationsAreNeverReusedAcrossSessionsOrReattachments() async throws {
        let fixture = try await LaunchFixture.make(); defer { fixture.cleanup() }
        let session = try await fixture.runtime.launch(fixture.request)
        let terminals = await fixture.runtime.terminals
        let a = try await terminals.attach(sessionID: session.id, sink: RecordingSink(), cols: 100, rows: 30, takeControl: false)
        await terminals.detach(sessionID: session.id, generation: a)
        let b = try await terminals.attach(sessionID: session.id, sink: RecordingSink(), cols: 100, rows: 30, takeControl: false)
        let c = try await terminals.attach(sessionID: session.id, sink: RecordingSink(), cols: 100, rows: 30, takeControl: true)
        #expect(a < b && b < c)
        var code: String?
        do { try await terminals.input(sessionID: session.id, generation: a, bytes: Data("x".utf8)) } catch let error as ChauffeurError { code = error.code }
        #expect(code == "attachment_revoked")
        await terminals.detach(sessionID: session.id, generation: c)
        do { try await terminals.input(sessionID: session.id, generation: c, bytes: Data("x".utf8)) } catch let error as ChauffeurError { code = error.code }
        #expect(code == "attachment_lost")
        _ = try await fixture.stop()
    }
}
