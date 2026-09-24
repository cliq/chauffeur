#if os(macOS)
import Foundation
import GhosttyKit

/// What a surface reports to its view, copied out of Ghostty's callbacks so it can cross threads.
enum GhosttySurfaceEvent: Sendable, Equatable {
    case title(String)
    case bell
    case openURL(String)
    case searchStarted
    case searchEnded
    case searchTotal(Int?)
    case searchSelected(Int?)
    case mouseShape(UInt32)
    case clipboardWrite(String)

    /// `nil` for actions a host-managed terminal ignores (splits, tabs, config reloads, ...), which
    /// Ghostty is then told were not handled.
    init?(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let title = action.action.set_title.title else { return nil }
            self = .title(String(cString: title))
        case GHOSTTY_ACTION_RING_BELL:
            self = .bell
        case GHOSTTY_ACTION_OPEN_URL:
            let payload = action.action.open_url
            guard let url = payload.url else { return nil }
            self = .openURL(String(decoding: UnsafeRawBufferPointer(start: url, count: Int(payload.len)), as: UTF8.self))
        case GHOSTTY_ACTION_START_SEARCH:
            self = .searchStarted
        case GHOSTTY_ACTION_END_SEARCH:
            self = .searchEnded
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            self = .searchTotal(total < 0 ? nil : Int(total))
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            self = .searchSelected(selected < 0 ? nil : Int(selected))
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            self = .mouseShape(action.action.mouse_shape.rawValue)
        default:
            return nil
        }
    }
}

/// The userdata Ghostty holds for one surface. The view keeps it alive until after
/// `ghostty_surface_free` returns, so a late callback never touches freed memory; the view itself
/// is held weakly.
final class GhosttySurfaceCallbacks: @unchecked Sendable {
    /// Read and written on the main thread only.
    nonisolated(unsafe) weak var view: GhosttySurfaceView?
    private let lock = NSLock()
    private var surface: ghostty_surface_t?

    func setSurface(_ surface: ghostty_surface_t?) {
        lock.lock(); self.surface = surface; lock.unlock()
    }

    func deliver(_ event: GhosttySurfaceEvent) {
        onMain { $0.handle(event) }
    }

    /// Bytes Ghostty generated for the remote process: typing, pastes and replies to queries.
    func receive(_ data: Data) {
        onMain { $0.handleGeneratedInput(data) }
    }

    /// The grid Ghostty applied, reported from its IO thread before it reflows. This is the only
    /// size the remote process should see, so a redraw never lands in a stale grid.
    func resize(columns: UInt16, rows: UInt16) {
        onMain { $0.handleGridResize(columns: Int(columns), rows: Int(rows)) }
    }

    func denyClipboardRequest(_ state: UnsafeMutableRawPointer) {
        let address = UInt(bitPattern: state)
        onMain { [self] _ in
            lock.lock(); let surface = surface; lock.unlock()
            guard let surface, let state = UnsafeMutableRawPointer(bitPattern: address) else { return }
            ghostty_surface_deny_clipboard_request(surface, state)
        }
    }

    private func onMain(_ body: @escaping @MainActor (GhosttySurfaceView) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { if let view { body(view) } }
        } else {
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { if let view { body(view) } }
            }
        }
    }
}

func ghosttyReceiveBuffer(_ userdata: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) {
    guard let userdata, let bytes, count > 0 else { return }
    Unmanaged<GhosttySurfaceCallbacks>.fromOpaque(userdata).takeUnretainedValue().receive(Data(bytes: bytes, count: count))
}

func ghosttyReceiveResize(_ userdata: UnsafeMutableRawPointer?, _ columns: UInt16, _ rows: UInt16, _ width: UInt32, _ height: UInt32) {
    guard let userdata else { return }
    Unmanaged<GhosttySurfaceCallbacks>.fromOpaque(userdata).takeUnretainedValue().resize(columns: columns, rows: rows)
}

/// Feeds output to a surface in order on a serial queue.
///
/// `ghostty_surface_write_buffer` parses synchronously and can block while Ghostty's app mailbox
/// is full, and only a main-thread tick drains that mailbox, so output must never be parsed on the
/// main thread. Output that arrives before the surface exists waits here and is flushed first.
final class GhosttyOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.chauffeur.ghostty.output", qos: .userInitiated)
    private let condition = NSCondition()
    private var surface: ghostty_surface_t?
    private var generation: UInt64 = 0
    private var activeWrites = 0
    private var pending: [(data: Data, replay: Bool)] = []
    private var pendingBytes = 0
    /// Beyond this, the oldest waiting output is dropped: a terminal's scrollback would have
    /// forgotten it anyway, and the next attachment resets and redraws.
    static let pendingByteLimit = 4 << 20

    func attach(_ surface: ghostty_surface_t) {
        condition.lock()
        generation &+= 1
        self.surface = surface
        let flush = pending, current = generation
        pending.removeAll(); pendingBytes = 0
        // Enqueued while the lock still excludes `enqueue`, so the flush precedes newer output.
        for chunk in flush {
            queue.async { [self] in write(chunk.data, replay: chunk.replay, generation: current) }
        }
        condition.unlock()
    }

    func enqueue(_ data: Data, replay: Bool) {
        guard !data.isEmpty else { return }
        condition.lock()
        guard surface != nil else {
            pending.append((data, replay)); pendingBytes += data.count
            while pendingBytes > Self.pendingByteLimit, !pending.isEmpty {
                pendingBytes -= pending.removeFirst().data.count
            }
            condition.unlock()
            return
        }
        let current = generation
        condition.unlock()
        queue.async { [self] in write(data, replay: replay, generation: current) }
    }

    /// Forgets output waiting for a surface; used by `reset()`, which replaces what came before.
    func discardPending() {
        condition.lock(); pending.removeAll(); pendingBytes = 0; condition.unlock()
    }

    /// Stops writing to the current surface and waits for a write in progress, ticking the app so
    /// a write blocked on the mailbox can finish. Queued writes for this surface are skipped.
    @MainActor
    func detach(ticking runtime: GhosttyRuntime?) {
        condition.lock()
        generation &+= 1
        surface = nil
        while activeWrites > 0 {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
            guard activeWrites > 0 else { break }
            condition.unlock()
            runtime?.tick()
            condition.lock()
        }
        condition.unlock()
    }

    /// Waits until everything enqueued so far has been parsed (tests and the Debug probe).
    @MainActor
    func waitUntilIdle(ticking runtime: GhosttyRuntime?) {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        while done.wait(timeout: .now() + 0.01) == .timedOut { runtime?.tick() }
    }

    private func write(_ data: Data, replay: Bool, generation expected: UInt64) {
        condition.lock()
        guard generation == expected, let surface else { condition.unlock(); return }
        activeWrites += 1
        condition.unlock()
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            if replay {
                ghostty_surface_write_buffer_replay(surface, base, UInt(buffer.count))
            } else {
                ghostty_surface_write_buffer(surface, base, UInt(buffer.count))
            }
        }
        condition.lock()
        activeWrites -= 1
        if activeWrites == 0 { condition.broadcast() }
        condition.unlock()
    }
}
#endif
