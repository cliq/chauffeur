import Foundation
import Darwin
import CChauffeur
import ChauffeurCore

/// Owns the one interactive authentication process allowed during setup. Its
/// output is ephemeral and bounded; it is never attached to a Session record.
public actor SetupLoginHost {
    private struct State {
        var operationID: UUID
        var process: SetupLoginProcess
        var generation: UInt64 = 0
        var controllerAttached = false
        var bytes = Data()
        var oldestCursor: UInt64 = 0
        var exitStatus: Int32?
        var waiters: [CheckedContinuation<Int32, Error>] = []
    }

    private var state: State?
    private var nextGeneration: UInt64 = 1
    private let outputLimit: Int
    private let readLimit: Int

    public init(outputLimit: Int = 1 << 20, readLimit: Int = 64 << 10) {
        self.outputLimit = max(1, outputLimit)
        self.readLimit = max(1, readLimit)
    }

    public func start(operationID: UUID, command: SetupCommand, cols: Int = 100, rows: Int = 30) async throws -> SetupLoginHandle {
        if let state {
            if state.operationID == operationID { return handle(for: state) }
            if state.exitStatus == nil {
                throw ChauffeurError("setup_login_busy", "Another setup sign-in is already running. Finish or cancel it before starting another.")
            }
        }
        let process = try SetupLoginProcess(command: command, cols: cols, rows: rows)
        state = State(operationID: operationID, process: process)
        process.start(
            onOutput: { [weak self] data in
                guard let self else { return }
                Task { await self.receive(data, operationID: operationID) }
            },
            onExit: { [weak self] status in
                guard let self else { return }
                Task { await self.finished(status, operationID: operationID) }
            }
        )
        return SetupLoginHandle(operationID: operationID, generation: 0, phase: .signingIn)
    }

    /// Acquires terminal control. A detached wizard can reconnect without
    /// restarting login; takeover invalidates the prior controller generation.
    public func attach(operationID: UUID, takeControl: Bool = false) throws -> SetupLoginHandle {
        guard var current = state, current.operationID == operationID else {
            throw ChauffeurError("setup_login_missing", "The setup sign-in is no longer available. Start it again.")
        }
        if current.controllerAttached && !takeControl {
            throw ChauffeurError("setup_login_controlled", "This setup sign-in is controlled by another window.")
        }
        current.generation = nextGeneration
        nextGeneration &+= 1
        if nextGeneration == 0 { nextGeneration = 1 }
        current.controllerAttached = true
        state = current
        return handle(for: current)
    }

    public func read(operationID: UUID, generation: UInt64, cursor: UInt64) throws -> SetupLoginOutput {
        let current = try controlled(operationID: operationID, generation: generation)
        let end = current.oldestCursor + UInt64(current.bytes.count)
        guard cursor <= end else { throw ChauffeurError("setup_login_cursor", "Terminal output cursor is ahead of available output") }
        let start = max(cursor, current.oldestCursor)
        let offset = Int(start - current.oldestCursor)
        let count = min(readLimit, current.bytes.count - offset)
        let bytes: Data
        if count > 0 {
            let lower = current.bytes.index(current.bytes.startIndex, offsetBy: offset)
            let upper = current.bytes.index(lower, offsetBy: count)
            bytes = current.bytes.subdata(in: lower..<upper)
        } else {
            bytes = Data()
        }
        return SetupLoginOutput(
            bytes: bytes,
            nextCursor: start + UInt64(count),
            oldestCursor: current.oldestCursor,
            running: current.exitStatus == nil,
            exitStatus: current.exitStatus,
            generation: current.generation
        )
    }

    public func input(operationID: UUID, generation: UInt64, bytes: Data) throws {
        try controlled(operationID: operationID, generation: generation).process.input(bytes)
    }

    public func resize(operationID: UUID, generation: UInt64, cols: Int, rows: Int) throws {
        try controlled(operationID: operationID, generation: generation).process.resize(cols: cols, rows: rows)
    }

    /// Releases UI control without changing the login process lifetime.
    public func detach(operationID: UUID, generation: UInt64) {
        guard var current = state, current.operationID == operationID,
              current.controllerAttached, current.generation == generation else { return }
        current.controllerAttached = false
        state = current
    }

    public func cancel(operationID: UUID) async throws {
        guard let current = state, current.operationID == operationID else { return }
        guard current.exitStatus == nil else { return }
        current.process.cancel()
        _ = try await waitForExit(operationID: operationID)
    }

    public func waitForExit(operationID: UUID) async throws -> Int32 {
        guard var current = state, current.operationID == operationID else {
            throw ChauffeurError("setup_login_missing", "The setup sign-in is no longer available.")
        }
        if let status = current.exitStatus { return status }
        return try await withCheckedThrowingContinuation { continuation in
            current.waiters.append(continuation)
            state = current
        }
    }

    public func status(operationID: UUID) -> SetupLoginHandle? {
        guard let current = state, current.operationID == operationID else { return nil }
        return handle(for: current)
    }

    private func controlled(operationID: UUID, generation: UInt64) throws -> State {
        guard let current = state, current.operationID == operationID else {
            throw ChauffeurError("setup_login_missing", "The setup sign-in is no longer available.")
        }
        guard current.controllerAttached, current.generation == generation else {
            throw ChauffeurError("setup_login_revoked", "Another window controls this setup sign-in.")
        }
        return current
    }

    private func handle(for current: State) -> SetupLoginHandle {
        let phase: SetupAuthPhase
        if let status = current.exitStatus {
            phase = status == 0 ? .verifying : .failed
        } else {
            phase = .signingIn
        }
        return SetupLoginHandle(operationID: current.operationID, generation: current.generation, phase: phase)
    }

    private func receive(_ data: Data, operationID: UUID) {
        guard var current = state, current.operationID == operationID, !data.isEmpty else { return }
        current.bytes.append(data)
        if current.bytes.count > outputLimit {
            let removed = current.bytes.count - outputLimit
            current.bytes.removeFirst(removed)
            current.oldestCursor += UInt64(removed)
        }
        state = current
    }

    private func finished(_ status: Int32, operationID: UUID) {
        guard var current = state, current.operationID == operationID, current.exitStatus == nil else { return }
        current.exitStatus = status
        let waiters = current.waiters
        current.waiters = []
        state = current
        waiters.forEach { $0.resume(returning: status) }
    }
}

private final class SetupLoginProcess: @unchecked Sendable {
    private let descriptor: Int32
    private let pid: Int32
    private let lock = NSLock()
    private var stopped = false
    private var started = false

    init(command: SetupCommand, cols: Int, rows: Int) throws {
        try Self.validateSize(cols: cols, rows: rows)
        var argv = ([command.executable] + command.arguments).map { strdup($0) } + [nil]
        var envp = command.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var master: Int32 = -1
        pid = chauffeur_spawn_pty(command.executable, &argv, &envp, command.directory, &master, UInt16(cols), UInt16(rows))
        guard pid > 0 else { throw ChauffeurError("setup_login_pty", "Could not start the setup sign-in terminal", path: command.executable) }
        descriptor = master
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    deinit { Darwin.close(descriptor) }

    func start(onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            while true {
                let ready = Darwin.poll(&pollDescriptor, 1, 250)
                if ready < 0 && errno == EINTR { continue }
                if ready < 0 { break }
                if ready > 0, pollDescriptor.revents & Int16(POLLIN) != 0 {
                    while true {
                        let count = Darwin.read(descriptor, &buffer, buffer.count)
                        if count > 0 { onOutput(Data(buffer[..<count])); continue }
                        if count < 0 && errno == EINTR { continue }
                        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
                        break
                    }
                }
                if ready > 0, pollDescriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
            }
            // Drain bytes queued with the final hangup notification.
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                onOutput(Data(buffer[..<count]))
            }
            var rawStatus: Int32 = 0
            while waitpid(pid, &rawStatus, 0) < 0 && errno == EINTR {}
            onExit(Self.exitStatus(rawStatus))
        }
    }

    func input(_ data: Data) throws {
        try Validation.require(data.count <= 1024 * 1024, "Terminal input is too large")
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw ChauffeurError("setup_login_closed", "The setup sign-in has ended") }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ChauffeurError("setup_login_input", "Could not send input to setup sign-in") }
                offset += count
            }
        }
    }

    func resize(cols: Int, rows: Int) throws {
        try Self.validateSize(cols: cols, rows: rows)
        guard chauffeur_resize(descriptor, UInt16(cols), UInt16(rows)) == 0 else {
            throw ChauffeurError("setup_login_resize", "Could not resize the setup sign-in terminal")
        }
    }

    func cancel() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        let group = pid
        lock.unlock()
        _ = kill(-group, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if kill(-group, 0) == 0 { _ = kill(-group, SIGKILL) }
        }
    }

    private static func validateSize(cols: Int, rows: Int) throws {
        try Validation.require((2...500).contains(cols) && (2...300).contains(rows), "Terminal dimensions must be 2–500 columns and 2–300 rows")
    }

    private static func exitStatus(_ raw: Int32) -> Int32 {
        let signal = raw & 0x7f
        return signal == 0 ? (raw >> 8) & 0xff : 128 + signal
    }
}
