import Foundation
import Observation
import ChauffeurRemoteProtocol
import ChauffeurTerminalInterface

public enum TerminalSessionState: Equatable, Sendable {
    case idle
    case attaching
    case attached(generation: UInt64)
    /// Another controller owns the terminal. Only an explicit `takeControl()` leaves this state.
    case controlLost(message: String)
    /// The attachment is gone for a recoverable reason; `handleForeground()` reattaches.
    case disconnected(message: String)
    case ended(reason: AttachmentEndReason)
}

/// Binds one terminal engine adapter to one remote session over a `RemoteConnection`: attaches,
/// feeds ordered output, forwards typed input and resizes, and reflects every way the attachment
/// can end. Output frames from another generation are dropped, and any gap in the sequence
/// numbers disconnects the terminal instead of rendering a discontinuous stream.
@MainActor
@Observable
public final class RemoteSessionController: TerminalEngineAdapterDelegate {
    public static let resizeDebounce: Duration = .milliseconds(100)
    /// Output frames that arrive between sending `attachTerminal` and handling its response are
    /// held so the first screen redraw is never lost. The host bounds output per attachment, so a
    /// small cap is enough to catch a misbehaving peer.
    static let maxFramesHeldWhileAttaching = 512

    public let sessionID: UUID
    public private(set) var state: TerminalSessionState = .idle
    /// Frames dropped because their generation was not the current one (diagnostics and tests).
    public private(set) var droppedStaleFrames = 0

    @ObservationIgnored private let connection: RemoteConnection
    @ObservationIgnored private let adapter: any TerminalEngineAdapter
    @ObservationIgnored private var generation: UInt64?
    @ObservationIgnored private var lastSequence: UInt64?
    @ObservationIgnored private var heldWhileAttaching: [TerminalFramePayload] = []
    @ObservationIgnored private var attachInFlight = false
    @ObservationIgnored private var subscribed = false

    @ObservationIgnored private let outputContinuation: AsyncStream<TerminalFramePayload>.Continuation
    @ObservationIgnored private let inputContinuation: AsyncStream<PendingInput>.Continuation
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var connectionStateTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResize: TerminalCellSize?

    /// Called for an OSC 52 copy request from the remote program. The app decides whether to
    /// write to the pasteboard; the controller and adapter never touch it.
    @ObservationIgnored public var onClipboardCopy: ((String) -> Void)?
    /// Called when the user taps a web or mail link in the terminal. The app decides whether to open it.
    @ObservationIgnored public var onOpenLink: ((String) -> Void)?

    private struct PendingInput: Sendable {
        var generation: UInt64
        var bytes: Data
    }

    public init(sessionID: UUID, connection: RemoteConnection, adapter: any TerminalEngineAdapter) {
        self.sessionID = sessionID
        self.connection = connection
        self.adapter = adapter

        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: TerminalFramePayload.self, bufferingPolicy: .unbounded)
        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: PendingInput.self, bufferingPolicy: .unbounded)
        self.outputContinuation = outputContinuation
        self.inputContinuation = inputContinuation

        adapter.delegate = self

        // One main-actor consumer per stream keeps bytes in wire order.
        outputTask = Task { [weak self] in
            for await payload in outputStream {
                guard let self else { return }
                self.handleOutput(payload)
            }
        }
        inputTask = Task { [weak self] in
            for await input in inputStream {
                guard let self else { return }
                // Re-check at send time: bytes typed for an attachment that has since ended are dropped, never replayed.
                guard case .attached(let current) = self.state, current == input.generation else { continue }
                try? await self.connection.sendTerminalInput(generation: input.generation, bytes: input.bytes)
            }
        }
    }

    deinit {
        outputTask?.cancel()
        inputTask?.cancel()
        eventsTask?.cancel()
        connectionStateTask?.cancel()
        resizeTask?.cancel()
        outputContinuation.finish()
        inputContinuation.finish()
    }

    // MARK: Attachment

    public func attach(takeControl: Bool) async {
        guard !attachInFlight else { return }
        attachInFlight = true
        defer { attachInFlight = false }

        await subscribeIfNeeded()

        adapter.setInputEnabled(false)
        adapter.reset()
        generation = nil
        lastSequence = nil
        heldWhileAttaching.removeAll()
        state = .attaching

        let size = adapter.cellSize
        let request = AttachTerminalRequest(sessionID: sessionID, takeControl: takeControl, cols: size.cols, rows: size.rows)
        do {
            let result = try await connection.request(.attachTerminal(request))
            guard case .attachment(let info) = result else {
                heldWhileAttaching.removeAll()
                state = .disconnected(message: "Unexpected attach response")
                return
            }
            generation = info.generation
            lastSequence = nil
            state = .attached(generation: info.generation)
            adapter.setInputEnabled(true)

            let held = heldWhileAttaching
            heldWhileAttaching.removeAll()
            for payload in held {
                handleOutput(payload)
            }
        } catch RemoteClientError.remote(let error) where error.code == "terminal_busy" {
            heldWhileAttaching.removeAll()
            state = .controlLost(message: error.message)
        } catch let error as RemoteClientError {
            heldWhileAttaching.removeAll()
            state = .disconnected(message: error.userMessage)
        } catch is CancellationError {
            // The caller went away (for example a SwiftUI task cancelled mid-transition); nothing
            // was attached, so stay idle and let the next appearance attach again.
            heldWhileAttaching.removeAll()
            state = .idle
        } catch {
            heldWhileAttaching.removeAll()
            state = .disconnected(message: String(describing: error))
        }
    }

    /// Explicit user action only: claims the terminal from whoever controls it now.
    public func takeControl() async {
        await attach(takeControl: true)
    }

    public func detach() async {
        adapter.setInputEnabled(false)
        resizeTask?.cancel()
        pendingResize = nil
        let current = generation
        generation = nil
        lastSequence = nil
        state = .idle
        if let current {
            _ = try? await connection.request(.detachTerminal(DetachTerminalRequest(generation: current)))
        }
    }

    /// Reattaches after a recoverable loss. Never leaves `.controlLost` or `.ended` on its own.
    public func handleForeground() async {
        guard case .disconnected = state else { return }
        guard case .ready = await connection.state else { return }
        await attach(takeControl: false)
    }

    // MARK: Output

    private func handleOutput(_ payload: TerminalFramePayload) {
        switch state {
        case .attaching:
            if heldWhileAttaching.count < Self.maxFramesHeldWhileAttaching {
                heldWhileAttaching.append(payload)
            } else {
                droppedStaleFrames += 1
            }
        case .attached(let current):
            guard payload.generation == current else {
                droppedStaleFrames += 1
                return
            }
            // The first frame of an attachment sets the baseline; every later one must be contiguous.
            if let last = lastSequence, payload.sequence != last &+ 1 {
                loseAttachment(message: "Output stream lost bytes")
                return
            }
            lastSequence = payload.sequence
            adapter.feed(payload.bytes)
        case .idle, .controlLost, .disconnected, .ended:
            droppedStaleFrames += 1
        }
    }

    private func loseAttachment(message: String) {
        adapter.setInputEnabled(false)
        resizeTask?.cancel()
        pendingResize = nil
        generation = nil
        lastSequence = nil
        state = .disconnected(message: message)
    }

    // MARK: Events

    private func subscribeIfNeeded() async {
        guard !subscribed else { return }
        subscribed = true

        let events = await connection.events()
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handleEvent(event)
            }
        }

        let states = await connection.stateChanges()
        connectionStateTask = Task { [weak self] in
            for await connectionState in states {
                guard let self else { return }
                self.handleConnectionState(connectionState)
            }
        }

        let continuation = outputContinuation
        await connection.setTerminalOutputHandler { payload in
            continuation.yield(payload)
        }
    }

    private func handleEvent(_ event: RemoteEvent) {
        switch event {
        case .attachmentEnded(let endedGeneration, let reason, let message):
            guard let generation, endedGeneration == generation else { return }
            adapter.setInputEnabled(false)
            resizeTask?.cancel()
            pendingResize = nil
            self.generation = nil
            lastSequence = nil
            switch reason {
            case .controlLost, .revoked:
                state = .controlLost(message: message ?? "Another device took control of this terminal.")
            case .sessionEnded:
                state = .ended(reason: reason)
            case .slowConsumer, .transportClosed:
                state = .disconnected(message: message ?? "The terminal stream was interrupted.")
            case .clientDetached:
                state = .idle
            }
        case .accessRevoked:
            adapter.setInputEnabled(false)
            generation = nil
            lastSequence = nil
            state = .disconnected(message: "Access revoked")
        case .inventoryChanged, .sessionChanged, .operationUpdated:
            break
        }
    }

    private func handleConnectionState(_ connectionState: RemoteConnection.State) {
        let message: String
        switch connectionState {
        case .failed(let error):
            message = error.userMessage
        case .closed:
            message = RemoteClientError.disconnected.userMessage
        case .idle, .connecting, .ready:
            return
        }
        switch state {
        case .ended:
            return
        case .idle, .attaching, .attached, .controlLost, .disconnected:
            loseAttachment(message: message)
        }
    }

    // MARK: TerminalEngineAdapterDelegate

    public func terminal(_ adapter: any TerminalEngineAdapter, didGenerateInput data: Data) {
        // Input outside an attachment is dropped, never queued: keystrokes are not retryable.
        guard case .attached(let current) = state else { return }
        inputContinuation.yield(PendingInput(generation: current, bytes: data))
    }

    public func terminal(_ adapter: any TerminalEngineAdapter, didChangeCellSize size: TerminalCellSize) {
        guard case .attached = state else { return }
        pendingResize = size
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resizeDebounce)
            guard !Task.isCancelled, let self else { return }
            guard case .attached(let current) = self.state, let size = self.pendingResize else { return }
            self.pendingResize = nil
            let request = TerminalResizeRequest(generation: current, cols: size.cols, rows: size.rows)
            _ = try? await self.connection.request(.terminalResize(request))
        }
    }

    public func terminal(_ adapter: any TerminalEngineAdapter, didCopyToClipboard text: String) {
        onClipboardCopy?(text)
    }

    public func terminal(_ adapter: any TerminalEngineAdapter, didRequestOpenLink link: String) {
        onOpenLink?(link)
    }
}
