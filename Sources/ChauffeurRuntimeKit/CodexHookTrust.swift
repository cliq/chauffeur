import Foundation
import Darwin
import ChauffeurCore

/// Codex skips hooks it does not trust. Chauffeur trusts exactly its own
/// session-flag hooks, one launch at a time, by passing their current hashes
/// as a whole `hooks.state` map. The hashes come from `hooks/list` in an
/// isolated `CODEX_HOME`; nothing is written to the user's Codex configuration.
public enum CodexHookTrust {
    public static let unavailableMessage = "Inbox reminders unavailable for this Codex version"
    /// A hook Chauffeur adds with `-c hooks.<event>=[…]`.
    public struct Definition: Equatable, Sendable {
        public var event: String
        public var command: String
        public init(event: String, command: String) { self.event = event; self.command = command }
    }

    /// Hash per `hooks/list` key, or nil unless the session-flag hooks are
    /// exactly Chauffeur's definitions. An unexpected entry means no trust.
    public static func trustedHashes(hooksList response: JSONValue, expected: [Definition]) -> [String: String]? {
        let listed = response["result"]["data"].array.flatMap { $0["hooks"].array }.filter { $0["source"].string == "sessionFlags" }
        guard !expected.isEmpty, listed.count == expected.count else { return nil }
        var remaining = expected, hashes: [String: String] = [:]
        for entry in listed {
            guard entry["handlerType"].string == "command", entry["enabled"].bool != false,
                  let key = entry["key"].string, key.hasPrefix("/<session-flags>/"),
                  let hash = entry["currentHash"].string, hash.hasPrefix("sha256:"),
                  let index = remaining.firstIndex(where: { lowerFirst($0.event) == entry["eventName"].string && $0.command == entry["command"].string }) else { return nil }
            remaining.remove(at: index); hashes[key] = hash
        }
        return remaining.isEmpty && hashes.count == expected.count ? hashes : nil
    }

    /// One whole inline table: Codex ignores dotted `hooks.state."key".…` overrides.
    public static func stateArgument(_ hashes: [String: String]) throws -> String {
        let entries = try hashes.sorted { $0.key < $1.key }.map { "\(try tomlString($0.key))={trusted_hash=\(try tomlString($0.value))}" }
        return "hooks.state={\(entries.joined(separator: ","))}"
    }

    /// Cached by executable path, reported version and the exact hook flags.
    public static func resolve(executable: String, version: String, hookArguments: [String], expected: [Definition], environment: [String: String], cacheDirectory: URL, timeout: TimeInterval = 5) async -> [String: String]? {
        let key = JSONCoding.digest((try? JSONCoding.encode([executable, version] + hookArguments)) ?? Data())
        let cacheFile = cacheDirectory.appendingPathComponent("codex-hook-trust.json")
        var cache = (try? JSONCoding.decode([String: [String: String]].self, from: Data(contentsOf: cacheFile))) ?? [:]
        if let hashes = cache[key] { return hashes }
        guard let response = await listHooks(executable: executable, hookArguments: hookArguments, environment: environment, timeout: timeout),
              let hashes = trustedHashes(hooksList: response, expected: expected) else { return nil }
        cache[key] = hashes
        if cache.count > 20 { cache = [key: hashes] }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? JSONCoding.encode(cache).write(to: cacheFile, options: .atomic)
        return hashes
    }

    /// Runs `codex app-server --stdio` against an empty temporary `CODEX_HOME`
    /// and returns its `hooks/list` response, or nil on any failure or timeout.
    static func listHooks(executable: String, hookArguments: [String], environment: [String: String], timeout: TimeInterval) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: listHooksSync(executable: executable, hookArguments: hookArguments, environment: environment, timeout: timeout))
            }
        }
    }
    private static func listHooksSync(executable: String, hookArguments: [String], environment: [String: String], timeout: TimeInterval) -> JSONValue? {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("chauffeur-codex-trust-\(UUID().uuidString)")
        guard (try? fileManager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        defer { try? fileManager.removeItem(at: home) }
        var environment = environment
        environment["CODEX_HOME"] = home.path
        environment.removeValue(forKey: "CHAUFFEUR_SESSION_TOKEN")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"] + hookArguments
        process.currentDirectoryURL = home
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        defer {
            if process.isRunning { process.terminate() }
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
        }
        let messages: [JSONValue] = [
            .object(["id": .number(1), "method": .string("initialize"), "params": .object(["clientInfo": .object(["name": .string("chauffeur"), "version": .string("1")]), "capabilities": .object(["experimentalApi": .bool(true)])])]),
            .object(["method": .string("initialized")]),
            .object(["id": .number(2), "method": .string("hooks/list"), "params": .object(["cwds": .array([.string(home.path)])])]),
        ]
        for message in messages {
            // app-server reads JSON Lines; JSONCoding pretty-prints.
            guard let data = try? JSONEncoder().encode(message), (try? input.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))) != nil else { return nil }
        }
        let result = LockedValue<JSONValue?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var buffer = Data()
            defer { done.signal() }
            // availableData returns what has arrived; read(upToCount:) would wait for EOF.
            while buffer.count < 4 * 1024 * 1024, case let chunk = output.fileHandleForReading.availableData, !chunk.isEmpty {
                buffer += chunk
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]; buffer = Data(buffer[buffer.index(after: newline)...])
                    if let value = try? JSONCoding.decode(JSONValue.self, from: Data(line)), value["id"].int == 2 {
                        result.set(value["error"] == .null ? value : nil); return
                    }
                }
            }
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return result.get()
    }

    private static func lowerFirst(_ value: String) -> String { value.prefix(1).lowercased() + value.dropFirst() }
    private static func tomlString(_ value: String) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}
