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

public protocol CredentialStore: Sendable {
    func load() throws -> SavedHost?
    func save(_ host: SavedHost) throws
    func clear() throws
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case corruptData
}

/// Stores the saved host as one JSON generic-password item, readable after first unlock and
/// never synced or migrated to another device.
public final class KeychainCredentialStore: CredentialStore {
    private let service: String
    private let account: String

    public init(service: String, account: String = "saved-host") {
        self.service = service
        self.account = account
    }

    public func load() throws -> SavedHost? {
        var query = baseQuery()
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialStoreError.corruptData }
            do {
                return try JSONDecoder().decode(SavedHost.self, from: data)
            } catch {
                throw CredentialStoreError.corruptData
            }
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status)
        }
    }

    public func save(_ host: SavedHost) throws {
        let data = try JSONEncoder().encode(host)
        let query = baseQuery()
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

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [CFString: Any] {
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
    private var host: SavedHost?

    public init(host: SavedHost? = nil) {
        self.host = host
    }

    public func load() throws -> SavedHost? {
        lock.withLock { host }
    }

    public func save(_ host: SavedHost) throws {
        lock.withLock { self.host = host }
    }

    public func clear() throws {
        lock.withLock { host = nil }
    }
}
