import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

final class MutableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

struct RemoteAccessConfigurationTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-remote-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func freshConfigurationIsDisabledWithARandomKeyAndDefaultPorts() {
        let first = RemoteAccessConfiguration.fresh(build: .release)
        let second = RemoteAccessConfiguration.fresh(build: .release)
        #expect(!first.enabled)
        #expect(first.key.count == 32)
        #expect(first.hostID != second.hostID)
        #expect(first.key != second.key)
        #expect(RemoteAccessConfiguration.defaultPort(for: .release) == 51847)
        #expect(RemoteAccessConfiguration.defaultPort(for: .debug) == 51848)
        #expect(first.port == 51847)
        #expect(RemoteAccessConfiguration.fresh(build: .debug).port == 51848)
    }

    @Test func saveThenLoadRoundTripsWithPrivateFileMode() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAccessStore(root: root)
        var configuration = RemoteAccessConfiguration.fresh()
        configuration.enabled = true
        // JSON round-trips dates through ISO 8601 seconds; avoid sub-second precision here.
        let pairedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        configuration.devices.append(RemoteDeviceRecord(name: "iPhone", tokenHash: RemoteDeviceToken.hash("token"), pairedAt: pairedAt))
        try store.save(configuration)
        let loaded = try store.load()
        #expect(loaded == configuration)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        #expect((mode?.intValue ?? 0) & 0o777 == 0o600)
    }

    @Test func loadWithNoFileReturnsFreshAndCreatesNothing() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAccessStore(root: root)
        let loaded = try store.load()
        #expect(!loaded.enabled)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test func corruptFileThrowsRemoteAccessCorrupt() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAccessStore(root: root)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        #expect { try store.load() } throws: { error in
            (error as? ChauffeurError)?.code == "remote_access_corrupt"
        }
    }

    @Test func saveIsAtomicAndLeavesNoTemporaryFiles() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAccessStore(root: root)
        try store.save(.fresh())
        try store.save(.fresh())
        let entries = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        #expect(entries == ["remote-access.json"])
    }

    @Test func deviceTokenGenerationAndHashing() {
        let first = RemoteDeviceToken.generate()
        let second = RemoteDeviceToken.generate()
        #expect(first != second)
        for token in [first, second] {
            #expect(!token.contains("+") && !token.contains("/") && !token.contains("="))
        }
        let hash = RemoteDeviceToken.hash(first)
        let isAllHexDigits = hash.allSatisfy { $0.isHexDigit }
        #expect(hash.count == 64)
        #expect(isAllHexDigits)
        #expect(RemoteDeviceToken.hash(first) == hash)
    }

    @Test func pairingCodeNormalization() {
        let lowercaseWithHyphens = PairingCode("k7q2-9mjx-4t")
        let uppercaseWithSpaces = PairingCode("K7Q2 9MJX 4T")
        #expect(lowercaseWithHyphens != nil)
        #expect(lowercaseWithHyphens?.value == uppercaseWithSpaces?.value)
        #expect(PairingCode(String(repeating: "A", count: 9)) == nil)
        #expect(PairingCode(String(repeating: "A", count: 11)) == nil)
        #expect(PairingCode("AAAAAAAAAU") == nil)
        let code = lowercaseWithHyphens!
        let expectedDisplay = String(code.value.prefix(4)) + "-" + String(code.value.dropFirst(4).prefix(4)) + "-" + String(code.value.suffix(2))
        #expect(code.display == expectedDisplay)
    }

    @Test func pairingCodeDerivedKey() {
        let code = PairingCode.generate()
        let otherCode = PairingCode.generate()
        let derived = code.derivedKey
        #expect(derived.count == 32)
        #expect(derived == code.derivedKey)
        #expect(derived != otherCode.derivedKey)
    }

    @Test func pairingCodeGenerateProducesValidCodesRepeatedly() {
        for _ in 0..<100 {
            let code = PairingCode.generate()
            #expect(code.value.count == 10)
            #expect(PairingCode(code.value)?.value == code.value)
        }
    }

    @Test func rateLimiterBlocksAfterThresholdAndRespectsClock() {
        let clock = MutableClock(Date())
        let limiter = RemoteRateLimiter(maxFailures: 5, window: 60, blockDuration: 60, clock: { clock.now })
        for _ in 0..<5 { limiter.recordFailure(for: "1.2.3.4") }
        #expect(limiter.isBlocked("1.2.3.4"))
        clock.now = clock.now.addingTimeInterval(30)
        #expect(limiter.isBlocked("1.2.3.4"))
        clock.now = clock.now.addingTimeInterval(31)
        #expect(!limiter.isBlocked("1.2.3.4"))
    }

    @Test func rateLimiterPrunesFailuresOutsideTheWindow() {
        let clock = MutableClock(Date())
        let limiter = RemoteRateLimiter(maxFailures: 5, window: 60, blockDuration: 60, clock: { clock.now })
        for _ in 0..<4 { limiter.recordFailure(for: "1.2.3.4") }
        clock.now = clock.now.addingTimeInterval(61)
        limiter.recordFailure(for: "1.2.3.4")
        #expect(!limiter.isBlocked("1.2.3.4"))
    }

    @Test func rateLimiterResetUnblocks() {
        let limiter = RemoteRateLimiter(maxFailures: 5, window: 60, blockDuration: 60, clock: { Date() })
        for _ in 0..<5 { limiter.recordFailure(for: "1.2.3.4") }
        #expect(limiter.isBlocked("1.2.3.4"))
        limiter.reset("1.2.3.4")
        #expect(!limiter.isBlocked("1.2.3.4"))
    }
}
