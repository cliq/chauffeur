import Foundation
import Security

/// Everything the phone needs to reconnect to one paired Mac.
public struct SavedHost: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { hostID }
    public var hostID: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var remoteAccessKey: Data
    public var deviceID: UUID
    public var deviceToken: String
    public var pairedAt: Date

    public init(
        hostID: UUID,
        name: String,
        host: String,
        port: Int,
        remoteAccessKey: Data,
        deviceID: UUID,
        deviceToken: String,
        pairedAt: Date
    ) {
        self.hostID = hostID
        self.name = name
        self.host = host
        self.port = port
        self.remoteAccessKey = remoteAccessKey
        self.deviceID = deviceID
        self.deviceToken = deviceToken
        self.pairedAt = pairedAt
    }
}

/// The Macs this phone has paired with, in pairing order.
public protocol CredentialStore: Sendable {
    func loadAll() throws -> [SavedHost]
    /// Replaces every saved Mac. An empty list removes the stored item.
    func saveAll(_ hosts: [SavedHost]) throws
}

public extension CredentialStore {
    /// Adds a Mac, or replaces the one with the same `hostID` in place (re-pairing).
    func save(_ host: SavedHost) throws {
        var hosts = try loadAll()
        if let index = hosts.firstIndex(where: { $0.hostID == host.hostID }) { hosts[index] = host } else { hosts.append(host) }
        try saveAll(hosts)
    }

    func remove(hostID: UUID) throws {
        let hosts = try loadAll()
        guard hosts.contains(where: { $0.hostID == hostID }) else { return }
        try saveAll(hosts.filter { $0.hostID != hostID })
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case corruptData
}

/// Stores the saved Macs as one JSON generic-password item, readable after first unlock and
/// never synced or migrated to another device. Builds that paired one Mac stored it under
/// `legacyAccount`; it is read until the next save replaces it.
public final class KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account: String
    private let legacyAccount: String

    public init(service: String, account: String = "saved-hosts", legacyAccount: String = "saved-host") {
        self.service = service
        self.account = account
        self.legacyAccount = legacyAccount
    }

    public func loadAll() throws -> [SavedHost] {
        if let data = try read(account) { return try Self.decode([SavedHost].self, data) }
        if let data = try read(legacyAccount) { return [try Self.decode(SavedHost.self, data)] }
        return []
    }

    public func saveAll(_ hosts: [SavedHost]) throws {
        if hosts.isEmpty { try delete(account) } else { try write(JSONEncoder().encode(hosts), to: account) }
        try delete(legacyAccount)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CredentialStoreError.corruptData }
    }

    private func read(_ account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialStoreError.corruptData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    private func write(_ data: Data, to account: String) throws {
        let query = baseQuery(account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            for (key, value) in attributes {
                insert[key] = value
            }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
        default:
            throw CredentialStoreError.keychain(updateStatus)
        }
    }

    private func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            // The data-protection keychain is the only one that honors kSecAttrAccessible on macOS,
            // and it is the iOS default.
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any
        ]
    }
}

public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [SavedHost]

    public init(hosts: [SavedHost] = []) {
        self.hosts = hosts
    }

    public func loadAll() throws -> [SavedHost] {
        lock.withLock { hosts }
    }

    public func saveAll(_ hosts: [SavedHost]) throws {
        lock.withLock { self.hosts = hosts }
    }
}

/// Stores the saved Macs as a 0600 JSON file in the app's Application Support directory.
/// A file from a build that paired one Mac is read until the next save replaces it.
///
/// Meant for builds that cannot use the data-protection keychain, such as unsigned simulator
/// builds (`errSecMissingEntitlement`, -34018). Signed builds should prefer the keychain.
public final class FileCredentialStore: CredentialStore {
    private let url: URL
    private let legacyURL: URL

    public init(url: URL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL ?? url.deletingLastPathComponent().appendingPathComponent("saved-host.json")
    }

    public convenience init(filename: String = "saved-hosts.json") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(url: base.appendingPathComponent(filename))
    }

    public func loadAll() throws -> [SavedHost] {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                return try JSONDecoder().decode([SavedHost].self, from: Data(contentsOf: url))
            }
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                return [try JSONDecoder().decode(SavedHost.self, from: Data(contentsOf: legacyURL))]
            }
        } catch is DecodingError { throw CredentialStoreError.corruptData }
        return []
    }

    public func saveAll(_ hosts: [SavedHost]) throws {
        if hosts.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(hosts)
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try data.write(to: url, options: options)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if FileManager.default.fileExists(atPath: legacyURL.path) { try FileManager.default.removeItem(at: legacyURL) }
    }
}

/// Uses the keychain and falls back to a file store only when the keychain reports a missing
/// entitlement, which is what unsigned development builds get. Every other keychain error is
/// surfaced unchanged.
public final class FallbackCredentialStore: CredentialStore {
    public static let missingEntitlement: OSStatus = -34018
    private let primary: any CredentialStore
    private let fallback: any CredentialStore

    public init(primary: any CredentialStore, fallback: any CredentialStore) {
        self.primary = primary
        self.fallback = fallback
    }

    private func run<T>(_ operation: (any CredentialStore) throws -> T) throws -> T {
        do { return try operation(primary) } catch CredentialStoreError.keychain(let status) where status == Self.missingEntitlement {
            return try operation(fallback)
        }
    }

    public func loadAll() throws -> [SavedHost] { try run { try $0.loadAll() } }
    public func saveAll(_ hosts: [SavedHost]) throws { try run { try $0.saveAll(hosts) } }
}
