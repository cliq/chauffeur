import Foundation
import Darwin
import OSLog
import ChauffeurCore
import ChauffeurRemoteProtocol

/// LAN listener that lets a paired iPhone talk to this Mac's runtime. Owns the
/// persisted remote-access configuration, the TLS-PSK main listener, the
/// short-lived pairing listener and every accepted client connection.
public actor RemoteAccessService {
    public static let maxConnections = 8
    public static let pairingFailureLimit = 5
    static let pairingHandshakeTimeout: TimeInterval = 10

    private let store: RemoteAccessStore
    private let runtime: RuntimeCoordinator
    private let dispatcher: any RemoteOperationDispatching
    private let hostName: String
    private let build: AppBuild
    private let pairingTimeout: TimeInterval
    private let rateLimiter = RemoteRateLimiter()
    private let logger = Logger(subsystem: "dev.chauffeur.runtime", category: "remote")

    private var configuration: RemoteAccessConfiguration?
    private var configurationError: String?
    private var listener: RemoteListener?
    private var listenerError: String?
    private var connections: [UUID: RemoteClientConnection] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    /// connection ID → device ID, present once hello succeeded.
    private var connectionDevices: [UUID: UUID] = [:]
    private var inventoryPoller: Task<Void, Never>?
    private var pairing: PairingState?
    private var lastSeenPersisted = Date.distantPast
    private var lastSeenDirty = false

    private struct PairingState {
        let code: PairingCode
        let expiresAt: Date
        let listener: RemoteListener
        var failures = 0
        var expiry: Task<Void, Never>?
        var transports: [RemoteTransport] = []
        var completing = false
    }

    public init(root: URL, runtime: RuntimeCoordinator, dispatcher: any RemoteOperationDispatching = UnavailableDispatcher(),
                hostName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                build: AppBuild = AppBuild.current, pairingTimeout: TimeInterval = 120) {
        self.store = RemoteAccessStore(root: root)
        self.runtime = runtime
        self.dispatcher = dispatcher
        self.hostName = hostName
        self.build = build
        self.pairingTimeout = pairingTimeout
    }

    // MARK: Configuration

    private func loadConfiguration() -> RemoteAccessConfiguration {
        if let configuration { return configuration }
        do {
            let loaded = try store.load()
            configuration = loaded
            return loaded
        } catch {
            configurationError = (error as? ChauffeurError)?.message ?? "Remote access configuration could not be read"
            let fresh = RemoteAccessConfiguration.fresh(build: build)
            configuration = fresh
            return fresh
        }
    }

    private func save(_ configuration: RemoteAccessConfiguration) throws {
        try store.save(configuration)
        self.configuration = configuration
        configurationError = nil
        lastSeenPersisted = Date()
        lastSeenDirty = false
    }

    /// `lastSeenAt` changes on every hello; write them at most once a minute.
    private func persistLastSeenIfDue() {
        guard lastSeenDirty, let configuration, Date().timeIntervalSince(lastSeenPersisted) >= 60 else { return }
        try? save(configuration)
    }

    // MARK: Public API

    public func startIfEnabled() async {
        guard loadConfiguration().enabled else { return }
        await startListener()
    }

    public func shutdown() async {
        endPairing()
        stopListener()
        await closeAllConnections(revoked: false)
        if lastSeenDirty, let configuration { try? store.save(configuration) }
    }

    public func status() -> RemoteAccessStatus {
        let configuration = loadConfiguration()
        let connected = Set(connectionDevices.values)
        let devices = configuration.devices.map {
            RemoteAccessStatus.Device(id: $0.id, name: $0.name, pairedAt: $0.pairedAt, lastSeenAt: $0.lastSeenAt, connected: connected.contains($0.id))
        }
        var listening = listener != nil
        var error = listenerError ?? configurationError
        if let listener, let failure = listener.failureDescription {
            listening = false
            error = "Remote access stopped listening: \(failure)"
        }
        let pairingStatus = pairing.map { RemoteAccessStatus.Pairing(code: $0.code.display, expiresAt: $0.expiresAt, port: configuration.pairingPort) }
        return RemoteAccessStatus(enabled: configuration.enabled, listening: listening, port: configuration.port, hostName: hostName,
                                  addresses: Self.lanAddresses(), keyFingerprint: configuration.keyFingerprint, error: error,
                                  devices: devices, pairing: pairingStatus)
    }

    /// Persists the switch and starts or stops the main listener. The port can
    /// only change while remote access is disabled.
    public func setEnabled(_ enabled: Bool, port: Int?) async throws -> RemoteAccessStatus {
        var configuration = loadConfiguration()
        if let port {
            guard (1024...65535).contains(port) else { throw ChauffeurError("invalid_port", "Port must be between 1024 and 65535") }
            if port != configuration.port {
                guard !configuration.enabled else { throw ChauffeurError("remote_access_enabled", "Disable remote access before changing its port") }
                configuration.port = port
            }
        }
        configuration.enabled = enabled
        try save(configuration)
        if enabled {
            if listener == nil { await startListener() }
        } else {
            endPairing()
            stopListener()
            await closeAllConnections(revoked: false)
        }
        return status()
    }

    /// Opens the pairing port with a key derived from a fresh code. Pairing ends
    /// after one success, five failed handshakes or `pairingTimeout` seconds.
    public func beginPairing() async throws -> RemoteAccessStatus {
        let configuration = loadConfiguration()
        guard configuration.enabled, listener != nil else { throw ChauffeurError("remote_access_disabled", "Enable remote access before pairing a device") }
        endPairing()
        let code = PairingCode.generate()
        let pairingListener: RemoteListener
        do {
            pairingListener = try RemoteListener(psk: code.derivedKey, port: configuration.pairingPort, label: "pairing") { [weak self] transport in
                guard let self else { transport.cancel(); return }
                Task { await self.acceptPairing(transport) }
            }
            try await pairingListener.start()
        } catch {
            throw ChauffeurError("pairing_unavailable", "Could not open pairing port \(configuration.pairingPort): \(error)")
        }
        var state = PairingState(code: code, expiresAt: Date().addingTimeInterval(pairingTimeout), listener: pairingListener)
        let timeout = pairingTimeout
        state.expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.expirePairing(code: code)
        }
        pairing = state
        logger.info("Pairing started on port \(configuration.pairingPort, privacy: .public)")
        return status()
    }

    public func cancelPairing() -> RemoteAccessStatus {
        endPairing()
        return status()
    }

    /// Forgets the device, tells its live connections and detaches their terminals.
    public func revokeDevice(_ id: UUID) async throws -> RemoteAccessStatus {
        var configuration = loadConfiguration()
        guard let index = configuration.devices.firstIndex(where: { $0.id == id }) else { throw ChauffeurError("missing_device", "This device is no longer paired") }
        configuration.devices.remove(at: index)
        try save(configuration)
        let affected = connectionDevices.filter { $0.value == id }.map(\.key)
        for connectionID in affected { connectionDevices.removeValue(forKey: connectionID) }
        let revoked = affected.compactMap { connections[$0] }
        await withTaskGroup(of: Void.self) { group in
            for connection in revoked { group.addTask { await connection.revoke() } }
        }
        logger.info("Revoked remote device \(id.uuidString, privacy: .public)")
        return status()
    }

    /// New key and host identity; every paired device has to pair again.
    public func resetAccess() async throws -> RemoteAccessStatus {
        endPairing()
        var configuration = loadConfiguration()
        configuration.key = RemoteAccessCrypto.randomBytes(32)
        configuration.hostID = UUID()
        configuration.devices = []
        try save(configuration)
        stopListener()
        await closeAllConnections(revoked: true)
        if configuration.enabled { await startListener() }
        logger.info("Remote access reset; key \(configuration.keyFingerprint, privacy: .public)")
        return status()
    }

    // MARK: Main listener

    private func startListener() async {
        let configuration = loadConfiguration()
        stopListener()
        var lastError: Error?
        // A listener cancelled moments ago can still hold the port briefly.
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(200)) }
            do {
                let listener = try RemoteListener(psk: configuration.key, port: configuration.port, label: "main") { [weak self] transport in
                    guard let self else { transport.cancel(); return }
                    Task { await self.accept(transport) }
                }
                // Registered before it is ready so the very first accepted
                // connection is never refused as arriving while stopped.
                self.listener = listener
                do { try await listener.start() } catch { self.listener = nil; throw error }
                listenerError = nil
                startInventoryPolling()
                logger.info("Remote access listening on port \(configuration.port, privacy: .public); key \(configuration.keyFingerprint, privacy: .public)")
                return
            } catch {
                lastError = error
            }
        }
        listenerError = "Could not listen on port \(configuration.port): \(lastError.map { "\($0)" } ?? "unknown error")"
        logger.error("Remote access could not listen on port \(configuration.port, privacy: .public)")
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
        inventoryPoller?.cancel()
        inventoryPoller = nil
    }

    private func closeAllConnections(revoked: Bool) async {
        let current = Array(connections.values)
        connectionDevices = [:]
        await withTaskGroup(of: Void.self) { group in
            for connection in current {
                group.addTask { if revoked { await connection.revoke() } else { await connection.close() } }
            }
        }
    }

    private func accept(_ transport: RemoteTransport) {
        guard listener != nil, loadConfiguration().enabled else { transport.cancel(); return }
        guard connections.count < Self.maxConnections else {
            logger.notice("Remote connection refused: limit of \(Self.maxConnections) reached")
            transport.cancel(); return
        }
        guard !rateLimiter.isBlocked(transport.remoteAddress) else { transport.cancel(); return }
        let connection = RemoteClientConnection(transport: transport, service: self, runtime: runtime, dispatcher: dispatcher)
        connections[connection.id] = connection
        connectionTasks[connection.id] = Task { [weak self] in
            await connection.run()
            await self?.connectionClosed(connection.id)
        }
    }

    private func connectionClosed(_ id: UUID) {
        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
        connectionDevices.removeValue(forKey: id)
    }

    /// Verifies a hello against the paired devices. Failures count towards the
    /// per-address rate limit; success records the device as connected.
    func authenticate(_ hello: HelloRequest, connectionID: UUID, remoteAddress: String) -> Result<HostInfo, RemoteError> {
        guard hello.protocolVersion == RemoteProtocol.version else {
            return .failure(RemoteError(code: "protocol_mismatch", message: "Host protocol \(RemoteProtocol.version), client \(hello.protocolVersion)"))
        }
        var configuration = loadConfiguration()
        guard let index = configuration.devices.firstIndex(where: { $0.id == hello.deviceID }),
              Self.constantTimeEquals(RemoteDeviceToken.hash(hello.deviceToken), configuration.devices[index].tokenHash) else {
            rateLimiter.recordFailure(for: remoteAddress)
            return .failure(RemoteError(code: "unauthorized", message: "This device is not paired with this Mac"))
        }
        configuration.devices[index].lastSeenAt = Date()
        self.configuration = configuration
        lastSeenDirty = true
        persistLastSeenIfDue()
        connectionDevices[connectionID] = hello.deviceID
        return .success(HostInfo(hostID: configuration.hostID, hostName: hostName, runtimeVersion: RuntimeVersion.current, build: build.rawValue,
                                 protocolVersion: RemoteProtocol.version, capabilities: RemoteProtocol.capabilities))
    }

    private func startInventoryPolling() {
        inventoryPoller?.cancel()
        let dispatcher = self.dispatcher
        inventoryPoller = Task { [weak self] in
            var last = await dispatcher.inventoryRevision()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                let revision = await dispatcher.inventoryRevision()
                guard revision != last else { continue }
                last = revision
                guard let self else { return }
                await self.broadcast(.inventoryChanged(revision: revision))
            }
        }
    }

    private func broadcast(_ event: RemoteEvent) {
        for (id, connection) in connections where connectionDevices[id] != nil {
            Task { await connection.sendEvent(event) }
        }
    }

    // MARK: Pairing listener

    private func endPairing() {
        guard let state = pairing else { return }
        pairing = nil
        state.expiry?.cancel()
        state.listener.cancel()
        for transport in state.transports { transport.cancel() }
    }

    private func expirePairing(code: PairingCode) {
        guard pairing?.code == code else { return }
        logger.info("Pairing expired")
        endPairing()
    }

    private func pairingHandshakeFailed() {
        guard var state = pairing else { return }
        state.failures += 1
        pairing = state
        if state.failures >= Self.pairingFailureLimit {
            logger.notice("Pairing stopped after \(state.failures, privacy: .public) failed handshakes")
            endPairing()
        }
    }

    private func acceptPairing(_ transport: RemoteTransport) async {
        guard pairing != nil else { transport.cancel(); return }
        pairing?.transports.append(transport)
        defer { pairing?.transports.removeAll { $0 === transport } }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(Self.pairingHandshakeTimeout))
            guard !Task.isCancelled else { return }
            transport.cancel()
        }
        defer { deadline.cancel() }
        do { try await transport.start(timeout: Self.pairingHandshakeTimeout) }
        catch {
            pairingHandshakeFailed()
            return
        }
        var decoder = RemoteFrameDecoder()
        do {
            while let chunk = try await transport.receive(maximumLength: RemoteClientConnection.readChunk) {
                if chunk.isEmpty { continue }
                guard let frame = try decoder.append(chunk).first else { continue }
                try await completePairing(frame, over: transport)
                return
            }
        } catch { }
        transport.cancel()
    }

    private func completePairing(_ frame: RemoteFrame, over transport: RemoteTransport) async throws {
        guard frame.type == .request, let request = try? RemoteJSON.decode(RemoteRequest.self, from: frame.payload) else { throw RemoteProtocolViolation.malformedRequest }
        func reject(_ error: RemoteError) async throws -> Never {
            try? await Self.send(RemoteResponse(id: request.id, error: error), over: transport)
            throw RemoteProtocolViolation.unauthorized
        }
        guard case .pair(let pair) = request.operation else { try await reject(RemoteError(code: "pair_required", message: "The pairing port only accepts pair requests")) }
        guard pair.protocolVersion == RemoteProtocol.version else {
            try await reject(RemoteError(code: "protocol_mismatch", message: "Host protocol \(RemoteProtocol.version), client \(pair.protocolVersion)"))
        }
        guard pairing != nil, pairing?.completing == false else { try await reject(RemoteError(code: "pairing_closed", message: "Pairing is no longer open")) }
        pairing?.completing = true
        var configuration = loadConfiguration()
        let token = RemoteDeviceToken.generate()
        let trimmed = pair.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((trimmed.isEmpty ? "iPhone" : trimmed).prefix(80))
        let record = RemoteDeviceRecord(name: name, tokenHash: RemoteDeviceToken.hash(token), pairedAt: Date())
        configuration.devices.append(record)
        do { try save(configuration) }
        catch {
            pairing?.completing = false
            try await reject(RemoteError(code: "remote_access_write_failed", message: "This Mac could not save the pairing"))
        }
        let result = PairingResult(remoteAccessKey: configuration.key, deviceID: record.id, deviceToken: token, mainPort: configuration.port, hostID: configuration.hostID, hostName: hostName)
        try? await Self.send(RemoteResponse(id: request.id, result: .pairing(result)), over: transport)
        // Pairing is over as soon as the result is on the wire; only this
        // connection stays open for a moment so the phone reads it and closes first.
        pairing?.transports.removeAll { $0 === transport }
        endPairing()
        logger.info("Paired remote device \(record.id.uuidString, privacy: .public)")
        let closer = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            transport.cancel()
        }
        _ = try? await transport.receive(maximumLength: 1024)
        closer.cancel()
        transport.cancel()
    }

    private static func send(_ response: RemoteResponse, over transport: RemoteTransport) async throws {
        try await transport.send(RemoteFraming.encode(RemoteFrame(type: .response, payload: try RemoteJSON.encode(response))))
    }

    // MARK: Helpers

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    /// IPv4 addresses of the Mac's up, non-loopback interfaces, excluding VPN
    /// tunnels, peer-to-peer links and self-assigned addresses.
    nonisolated static func lanAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(bitPattern: entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("bridge") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard !text.hasPrefix("169.254."), !addresses.contains(text) else { continue }
            addresses.append(text)
        }
        return addresses
    }
}
