import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct CodexHookTrustTests {
    private let ctl = #"/Users/o'neil/Chauffeur Tools/back\slash/chauffeurctl"#
    private var definitions: [CodexHookTrust.Definition] { CLIAdapter.codexHookDefinitions(ctlPath: ctl) }

    private func entry(_ definition: CodexHookTrust.Definition, index: Int = 0, source: String = "sessionFlags", hash: String? = nil) -> JSONValue {
        let snake = definition.event.reduce("") { $0 + ($1.isUppercase && !$0.isEmpty ? "_" : "") + $1.lowercased() }
        return .object(["key": .string(source == "sessionFlags" ? "/<session-flags>/config.toml:\(snake):\(index):0" : "/Users/me/.codex/hooks.json:\(snake):0:0"),
                        "eventName": .string(definition.event.prefix(1).lowercased() + definition.event.dropFirst()),
                        "handlerType": .string("command"), "command": .string(definition.command), "source": .string(source),
                        "enabled": .bool(true), "currentHash": .string(hash ?? "sha256:\(snake)"), "trustStatus": .string("untrusted")])
    }
    private func response(_ hooks: [JSONValue]) -> JSONValue {
        .object(["id": .number(2), "result": .object(["data": .array([.object(["cwd": .string("/tmp"), "hooks": .array(hooks)])])])])
    }
    private func session(kind: CLIKind, root: URL) -> Session {
        let set = PresetSet(name: "Fixture")
        let preset = AgentPreset(setID: set.id, name: "Fixture", kind: kind, executable: "/bin/false", configurationDirectory: root.path)
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/false", executableVersion: "codex-cli 0.156.1", workingDirectory: root.path, additionalPaths: [])
        var value = Session(projectID: UUID(), groupID: UUID(), title: "Fixture", launch: launch, folderID: UUID())
        value.nativeConversationID = UUID().uuidString.lowercased()
        return value
    }

    @Test func trustsOnlyExactlyChauffeursSessionFlagHooks() {
        let exact = definitions.map { entry($0) }
        let user = entry(CodexHookTrust.Definition(event: "PostToolUse", command: "/usr/local/bin/user-hook"), source: "user")
        let hashes = CodexHookTrust.trustedHashes(hooksList: response(exact + [user]), expected: definitions)
        #expect(hashes?.count == 4)
        #expect(hashes?["/<session-flags>/config.toml:post_tool_use:0:0"] == "sha256:post_tool_use")
        #expect(hashes?.keys.allSatisfy { $0.hasPrefix("/<session-flags>/") } == true, "User hooks are never trusted by Chauffeur")

        let extra = entry(CodexHookTrust.Definition(event: "PreToolUse", command: "/tmp/other"))
        #expect(CodexHookTrust.trustedHashes(hooksList: response(exact + [extra]), expected: definitions) == nil)
        #expect(CodexHookTrust.trustedHashes(hooksList: response(Array(exact.dropLast())), expected: definitions) == nil)
        var altered = definitions; altered[1].command += " --verbose"
        #expect(CodexHookTrust.trustedHashes(hooksList: response(altered.map { entry($0) }), expected: definitions) == nil)
        #expect(CodexHookTrust.trustedHashes(hooksList: response(definitions.map { entry($0, hash: "md5:x") }), expected: definitions) == nil)
        #expect(CodexHookTrust.trustedHashes(hooksList: .object(["id": .number(2), "error": .object([:])]), expected: definitions) == nil)
    }

    @Test func stateIsOneWholeInlineTable() throws {
        let argument = try CodexHookTrust.stateArgument(["/<session-flags>/config.toml:stop:0:0": "sha256:b", "/<session-flags>/config.toml:post_tool_use:0:0": "sha256:a"])
        #expect(argument == #"hooks.state={"/<session-flags>/config.toml:post_tool_use:0:0"={trusted_hash="sha256:a"},"/<session-flags>/config.toml:stop:0:0"={trusted_hash="sha256:b"}}"#)
    }

    @Test func codexArgumentsQuoteTheCtlPathAndOmitHooksWithoutTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-codex-args-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = session(kind: .codex, root: root)
        let trust = ["/<session-flags>/config.toml:stop:0:0": "sha256:abc"]
        let arguments = try CLIAdapter.arguments(session: value, endpoint: "http://127.0.0.1:1/mcp", ctlPath: ctl, integrationDirectory: root, coordination: true, resume: false, codexHookTrust: trust)
        let hooks = arguments.filter { $0.hasPrefix("hooks.") && !$0.hasPrefix("hooks.state") }
        #expect(hooks.map { String($0.prefix { $0 != "=" }) } == ["hooks.SessionStart", "hooks.UserPromptSubmit", "hooks.PostToolUse", "hooks.Stop"])
        #expect(arguments.contains(try CodexHookTrust.stateArgument(trust)))
        #expect(arguments.contains { $0.hasPrefix("notify=") } && arguments.contains { $0.hasPrefix("mcp_servers.chauffeur.url=") })
        for hook in hooks {
            // The TOML basic string decodes as JSON; the shell then splits it back into the exact argv.
            let literal = try #require(hook.range(of: #"command=(".*?(?<!\\)"),timeout=5"#, options: .regularExpression).map { String(hook[$0].dropFirst(8).dropLast(10)) })
            let command = try JSONCoding.decode(String.self, from: Data(literal.utf8))
            let shell = try ProcessRunnerSync.run("/bin/sh", ["-c", "for a in \(command); do printf '%s\\n' \"$a\"; done"])
            #expect(shell.split(separator: "\n").map(String.init).first == ctl)
        }
        #expect(!hooks.contains { $0.contains(value.id.uuidString) }, "Commands are identical across sessions")
        let untrusted = try CLIAdapter.arguments(session: value, endpoint: "http://127.0.0.1:1/mcp", ctlPath: ctl, integrationDirectory: root, coordination: true, resume: true, codexHookTrust: nil)
        #expect(!untrusted.contains { $0.hasPrefix("hooks.") })
        #expect(untrusted.suffix(2) == ["resume", value.nativeConversationID!])
        let basic = try CLIAdapter.arguments(session: value, endpoint: "", ctlPath: ctl, integrationDirectory: root, coordination: false, resume: false, codexHookTrust: trust)
        #expect(!basic.contains { $0.hasPrefix("hooks.") })
    }

    @Test func resolveCachesByExecutableVersionAndFlagsAndTimesOut() async throws {
        let root = URL(fileURLWithPath: "/tmp/chauffeur-trust-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = try CLIAdapter.codexHookArguments(definitions)
        try JSONCoding.encode(response(definitions.map { entry($0) })).write(to: root.appendingPathComponent("listed.json"))
        // A stand-in app-server: answers hooks/list after initialize, counts runs,
        // and checks it got an isolated CODEX_HOME and no session credential.
        let fake = root.appendingPathComponent("codex")
        try """
        #!/usr/bin/python3
        import json, os, sys
        open('\(root.path)/runs', 'a').write(os.environ.get('CODEX_HOME', '') + ' ' + str('CHAUFFEUR_SESSION_TOKEN' in os.environ) + '\\n')
        if os.path.exists('\(root.path)/hang'):
            import time; time.sleep(30)
        for line in sys.stdin:
            m = json.loads(line)
            if m.get('id') == 1: print(json.dumps({'id': 1, 'result': {}}), flush=True)
            if m.get('id') == 2: print(open('\(root.path)/listed.json').read().replace('\\n', ''), flush=True)
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let environment = ["PATH": "/usr/bin:/bin", "CHAUFFEUR_SESSION_TOKEN": "secret", "CODEX_HOME": "/Users/me/.codex"]
        let cache = root.appendingPathComponent("cache")
        func resolve(version: String = "codex-cli 0.156.1", timeout: TimeInterval = 5) async -> [String: String]? {
            await CodexHookTrust.resolve(executable: fake.path, version: version, hookArguments: arguments, expected: definitions, environment: environment, cacheDirectory: cache, timeout: timeout)
        }
        #expect(await resolve()?.count == 4)
        #expect(await resolve()?.count == 4)
        var runs = try String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8).split(separator: "\n")
        #expect(runs.count == 1, "The second launch reuses the cached hashes")
        #expect(runs[0].hasSuffix(" False") && !runs[0].hasPrefix("/Users/me/.codex"))
        let isolatedHome = String(runs[0].split(separator: " ")[0])
        #expect(!FileManager.default.fileExists(atPath: isolatedHome), "The temporary CODEX_HOME is removed")

        try Data().write(to: root.appendingPathComponent("hang"))
        let start = ContinuousClock.now
        #expect(await resolve(version: "codex-cli 9.9.9", timeout: 0.5) == nil)
        #expect(start.duration(to: .now) < .seconds(3))
        runs = try String(contentsOf: root.appendingPathComponent("runs"), encoding: .utf8).split(separator: "\n")
        #expect(runs.count == 2, "A new version is not served from the old cache entry")
    }
}

/// Small synchronous helper for the shell-quoting check.
private enum ProcessRunnerSync {
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
