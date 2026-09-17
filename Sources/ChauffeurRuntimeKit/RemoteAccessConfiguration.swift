import Foundation
import CryptoKit
import Darwin
import ChauffeurCore
import ChauffeurRemoteProtocol

public struct RemoteDeviceRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Lowercase hex SHA-256 of the bearer token. The token itself is never stored.
    public var tokenHash: String
    public var pairedAt: Date
    public var lastSeenAt: Date?

    public init(id: UUID = UUID(), name: String, tokenHash: String, pairedAt: Date, lastSeenAt: Date? = nil) {
        self.id = id
        self.name = name
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct RemoteAccessConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var port: Int
    /// Stable identity of this Mac's remote access, generated once.
    public var hostID: UUID
    /// 32 random bytes; the TLS pre-shared key.
    public var key: Data
    public var devices: [RemoteDeviceRecord] = []
    public var version: Int = 1

    public init(enabled: Bool = false, port: Int, hostID: UUID, key: Data, devices: [RemoteDeviceRecord] = [], version: Int = 1) {
        self.enabled = enabled
        self.port = port
        self.hostID = hostID
        self.key = key
        self.devices = devices
        self.version = version
    }

    public static func defaultPort(for build: AppBuild) -> Int {
        build == .release ? 51847 : 51848
    }

    /// Random key + hostID, disabled.
    public static func fresh(build: AppBuild = AppBuild.current) -> RemoteAccessConfiguration {
        RemoteAccessConfiguration(enabled: false, port: defaultPort(for: build), hostID: UUID(), key: RemoteAccessCrypto.randomBytes(32))
    }

    public var pairingPort: Int { port + 1 }

    /// First 8 bytes of SHA-256(key) as lowercase hex — safe to show in UI/logs.
    public var keyFingerprint: String {
        SHA256.hash(data: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Atomic, 0600 JSON persistence at `<root>/runtime/remote-access.json`.
public struct RemoteAccessStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var url: URL { root.appendingPathComponent("runtime/remote-access.json") }

    /// Returns `.fresh()` and does not write when the file is absent.
    public func load() throws -> RemoteAccessConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fresh() }
        do {
            let data = try Data(contentsOf: url)
            return try JSONCoding.decode(RemoteAccessConfiguration.self, from: data)
        } catch {
            throw ChauffeurError("remote_access_corrupt", "Remote access configuration is corrupt", path: url.path)
        }
    }

    public func save(_ configuration: RemoteAccessConfiguration) throws {
        let directory = url.deletingLastPathComponent()
        // The `runtime` directory already exists at runtime start; create it 0700 if missing.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONCoding.encode(configuration)
        let temp = directory.appendingPathComponent(".remote-access-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ChauffeurError("remote_access_write_failed", "Could not persist remote access configuration", path: url.path)
        }
        guard Darwin.rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw ChauffeurError("remote_access_write_failed", "Could not persist remote access configuration", path: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum RemoteAccessCrypto {
    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) })
    }
}

public enum RemoteDeviceToken {
    /// 32 random bytes, base64url without padding.
    public static func generate() -> String {
        RemoteAccessCrypto.randomBytes(32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256 of the UTF-8 token.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Pairing codes: 10 characters of Crockford base32, displayed grouped "XXXX-XXXX-XX".
public struct PairingCode: Equatable, Sendable {
    private static let alphabet = PairingKeyDerivation.alphabet

    /// Normalized: uppercase, no separators, I→1, L→1, O→0.
    public let value: String

    public init?(_ text: String) {
        guard let normalized = PairingKeyDerivation.normalize(text) else { return nil }
        self.value = normalized
    }

    private init(normalizedValue: String) { self.value = normalizedValue }

    public static func generate() -> PairingCode {
        var generator = SystemRandomNumberGenerator()
        let characters = (0..<PairingKeyDerivation.codeLength).map { _ in alphabet.randomElement(using: &generator)! }
        return PairingCode(normalizedValue: String(characters))
    }

    public var display: String { PairingKeyDerivation.display(value) }

    /// The pairing listener's TLS pre-shared key. Derived from the code alone: the phone
    /// does not know the host identity until pairing succeeds.
    public var derivedKey: Data { PairingKeyDerivation.derive(normalizedCode: value) }
}

/// In-memory sliding-window limiter, used by the listener for failed hello attempts per source address.
public final class RemoteRateLimiter: @unchecked Sendable {
    private let maxFailures: Int
    private let window: TimeInterval
    private let blockDuration: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    public init(maxFailures: Int = 5, window: TimeInterval = 60, blockDuration: TimeInterval = 60, clock: @Sendable @escaping () -> Date = { Date() }) {
        self.maxFailures = maxFailures
        self.window = window
        self.blockDuration = blockDuration
        self.clock = clock
    }

    public func recordFailure(for key: String) {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        prune(key: key, now: now)
        var entries = failures[key] ?? []
        entries.append(now)
        if entries.count >= maxFailures {
            blockedUntil[key] = now.addingTimeInterval(blockDuration)
            entries.removeAll()
        }
        failures[key] = entries
    }

    public func isBlocked(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        if let until = blockedUntil[key] {
            if now < until { return true }
            blockedUntil.removeValue(forKey: key)
        }
        prune(key: key, now: now)
        return false
    }

    public func reset(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        failures.removeValue(forKey: key)
        blockedUntil.removeValue(forKey: key)
    }

    private func prune(key: String, now: Date) {
        guard let entries = failures[key] else { return }
        let pruned = entries.filter { now.timeIntervalSince($0) <= window }
        if pruned.isEmpty { failures.removeValue(forKey: key) } else { failures[key] = pruned }
    }
}
