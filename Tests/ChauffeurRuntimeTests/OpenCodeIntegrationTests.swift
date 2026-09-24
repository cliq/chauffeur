import Foundation
import Testing
import ChauffeurCore
import ChauffeurRemoteProtocol
@testable import ChauffeurRuntimeKit

struct OpenCodeIntegrationTests {
    @Test func remoteInventoryNamesOpenCodeSessions() {
        #expect(RemoteInventoryBuilder.kind(.opencode) == .opencode)
        #expect(CLIKind.allCases.allSatisfy { RemoteInventoryBuilder.kind($0).rawValue == $0.rawValue })
    }

    private static let help = """
    Commands:
      opencode acp                 start ACP (Agent Client Protocol) server
      opencode serve               starts a headless opencode server
      opencode models [provider]   list all available models
    Options:
      -m, --model         model to use in the format of provider/model
      -s, --session       session id to continue
          --auto          auto-approve permissions that are not explicitly denied (dangerous!)
    """
    private func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    /// Answers like OpenCode 1.18: version on stdout, help on stderr, `models` one per line.
    private func fakeOpenCode(in root: URL, version: String = "1.18.32", help: String = help) throws -> String {
        let path = root.appendingPathComponent("opencode").path
        let script = """
        #!/bin/sh
        case "$1" in
          --version) echo '\(version)';;
          --help) cat >&2 <<'HELP'
        \(help)
        HELP
          ;;
          models) echo "config=${OPENCODE_CONFIG_DIR:-default}" >&2; printf 'opencode/big-pickle\\nlocal/qwen\\n\\nnot a model\\n';;
          *) exit 1;;
        esac
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        return path
    }
    private func session(_ root: URL, additionalPaths: [String] = [], raw: String = "") -> Session {
        let set = PresetSet(name: "Fixture")
        var preset = AgentPreset(setID: set.id, name: "OpenCode", kind: .opencode, executable: "/bin/false", configurationDirectory: root.path)
        preset.rawArguments = raw
        let launch = LaunchSnapshot(preset: preset, set: set, executablePath: "/bin/false", executableVersion: "1.18.32", workingDirectory: root.path, additionalPaths: additionalPaths)
        return Session(projectID: UUID(), groupID: UUID(), title: "Fixture", launch: launch, folderID: UUID())
    }
    private func code(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let error as ChauffeurError { return error.code } catch { return "unexpected" }
    }

    @Test func capabilitiesReadHelpFromStandardError() async throws {
        let root = try temporaryRoot("opencode-caps"); defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["PATH": "/usr/bin:/bin"]
        let capabilities = try await CLIAdapter.capabilities(executable: fakeOpenCode(in: root), kind: .opencode, environment: environment)
        #expect(capabilities.version == "1.18.32" && capabilities.coordination && capabilities.statusSignals)
        #expect(capabilities.resume && capabilities.delegatedYOLO && capabilities.additionalDirectories && capabilities.limitation == nil)
        #expect(TmuxHost.supportsFollowUp(kind: .opencode, version: capabilities.version))

        let other = try temporaryRoot("opencode-other"); defer { try? FileManager.default.removeItem(at: other) }
        let impostor = try await CLIAdapter.capabilities(executable: fakeOpenCode(in: other, help: "Usage: tool [options]"), kind: .opencode, environment: environment)
        #expect(!impostor.coordination && !impostor.statusSignals && impostor.limitation != nil && !impostor.resume && !impostor.delegatedYOLO)
        let claude = try await CLIAdapter.capabilities(executable: fakeOpenCode(in: other, version: "2.1.272 (Claude Code)"), kind: .opencode, environment: environment)
        #expect(!claude.coordination)
    }

    @Test func modelListingIsCachedPerExecutableAndConfiguration() async throws {
        let root = try temporaryRoot("opencode-models"); defer { try? FileManager.default.removeItem(at: root) }
        let executable = try fakeOpenCode(in: root)
        let cache = ModelSuggestionCache.url(root: root)
        await OpenCodeIntegration.refreshModels(executable: executable, environment: ["PATH": "/usr/bin:/bin"], cache: cache)
        await OpenCodeIntegration.refreshModels(executable: executable, environment: ["PATH": "/usr/bin:/bin", "OPENCODE_CONFIG_DIR": "/team"], cache: cache)
        #expect(ModelSuggestionCache.models(kind: .opencode, executable: executable, configurationDirectory: "", at: cache) == ["opencode/big-pickle", "local/qwen"])
        #expect(ModelSuggestionCache.models(kind: .opencode, executable: executable, configurationDirectory: "/team", at: cache) == ["opencode/big-pickle", "local/qwen"])
        // A failing listing leaves the cache alone and never fails the probe.
        await OpenCodeIntegration.refreshModels(executable: "/bin/false", environment: [:], cache: cache)
        #expect(ModelSuggestionCache.models(kind: .opencode, executable: "/bin/false", configurationDirectory: "", at: cache) == ["opencode/big-pickle", "local/qwen"], "Falls back to every listing")

        // The capability probe starts the listing in the background.
        let other = try temporaryRoot("opencode-models-probe"); defer { try? FileManager.default.removeItem(at: other) }
        let probed = try fakeOpenCode(in: other)
        let otherCache = ModelSuggestionCache.url(root: other)
        _ = try await CLIAdapter.capabilities(executable: probed, kind: .opencode, environment: ["PATH": "/usr/bin:/bin"], modelCache: otherCache)
        for _ in 0..<200 where ModelSuggestionCache.models(kind: .opencode, at: otherCache).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(ModelSuggestionCache.models(kind: .opencode, executable: probed, configurationDirectory: "", at: otherCache) == ["opencode/big-pickle", "local/qwen"])
    }

    @Test func newAndResumedLaunchArguments() throws {
        let root = try temporaryRoot("opencode-args"); defer { try? FileManager.default.removeItem(at: root) }
        var fresh = session(root, raw: "--model local/qwen")
        fresh.initialTask = "Fix the build"
        let launched = try CLIAdapter.launch(session: fresh, endpoint: "", ctlPath: "/bin/false", integrationDirectory: root, coordination: false, resume: false, preparation: LaunchPreparation())
        #expect(launched.arguments == ["--model", "local/qwen", "--prompt", "Fix the build"] && launched.environment.isEmpty)
        fresh.initialTask = "-v looks like a flag"
        #expect(try CLIAdapter.launch(session: fresh, endpoint: "", ctlPath: "/bin/false", integrationDirectory: root, coordination: false, resume: false, preparation: LaunchPreparation()).arguments.last == "--prompt=-v looks like a flag")

        var resumed = session(root)
        resumed.initialTask = "Not repeated"
        resumed.nativeConversationID = "ses_0123456789abcdefghijABCDEF"
        let resume = try CLIAdapter.launch(session: resumed, endpoint: "", ctlPath: "/bin/false", integrationDirectory: root, coordination: false, resume: true, preparation: LaunchPreparation())
        #expect(resume.arguments == ["-s", "ses_0123456789abcdefghijABCDEF"])
        for invalid in [nil, UUID().uuidString, "ses_short"] {
            resumed.nativeConversationID = invalid
            #expect(code { _ = try CLIAdapter.launch(session: resumed, endpoint: "", ctlPath: "/bin/false", integrationDirectory: root, coordination: false, resume: true, preparation: LaunchPreparation()) } == "resume_unavailable")
        }
        // The launch writes nothing into the integration directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func configurationContentAddsPluginMCPAndPermissions() throws {
        let root = try temporaryRoot("opencode-content"); defer { try? FileManager.default.removeItem(at: root) }
        let extra = ["/work/shared", "/work/docs"]
        let coordinated = try CLIAdapter.launch(session: session(root, additionalPaths: extra), endpoint: "http://127.0.0.1:4242/mcp", ctlPath: "/bin/false", integrationDirectory: root, coordination: true, resume: false, preparation: LaunchPreparation(), pluginPath: "/Library/Chauffeur Data/plugins/chauffeur-opencode.js")
        let content = try #require(coordinated.environment["OPENCODE_CONFIG_CONTENT"])
        #expect(coordinated.environment.count == 1 && !content.contains("\n"))
        let expected: JSONValue = .object([
            "plugin": .array([.string("file:///Library/Chauffeur%20Data/plugins/chauffeur-opencode.js")]),
            "mcp": .object(["chauffeur": .object([
                "type": .string("remote"), "url": .string("http://127.0.0.1:4242/mcp"),
                "headers": .object(["Authorization": .string("Bearer {env:CHAUFFEUR_SESSION_TOKEN}")]),
                "timeout": .number(300_000)])]),
            "permission": .object(["chauffeur_*": .string("allow"),
                                   "external_directory": .object(["/work/shared/**": .string("allow"), "/work/docs/**": .string("allow")])])
        ])
        #expect(try JSONCoding.decode(JSONValue.self, from: Data(content.utf8)) == expected)

        let basic = try CLIAdapter.launch(session: session(root, additionalPaths: extra), endpoint: "", ctlPath: "/bin/false", integrationDirectory: root, coordination: false, resume: false, preparation: LaunchPreparation())
        let grants = try JSONCoding.decode(JSONValue.self, from: Data(try #require(basic.environment["OPENCODE_CONFIG_CONTENT"]).utf8))
        #expect(grants == .object(["permission": .object(["external_directory": .object(["/work/shared/**": .string("allow"), "/work/docs/**": .string("allow")])])]))
        #expect(code { _ = try CLIAdapter.launch(session: session(root), endpoint: "http://x", ctlPath: "/bin/false", integrationDirectory: root, coordination: true, resume: false, preparation: LaunchPreparation()) } == "integration_unavailable", "Coordination needs the plugin")
    }

    @Test func pluginIsPublishedAndRefreshedWhenItChanges() throws {
        let root = try temporaryRoot("opencode-plugin"); defer { try? FileManager.default.removeItem(at: root) }
        let path = try #require(try OpenCodeIntegration().publishPlugin(root: root))
        #expect(path == root.appendingPathComponent("plugins/chauffeur-opencode.js").path)
        let bundled = try OpenCodePlugin.bundledSource()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bundled)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        _ = try OpenCodeIntegration().publishPlugin(root: root)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bundled)
        #expect(try ClaudeIntegration().publishPlugin(root: root) == nil && CodexIntegration().publishPlugin(root: root) == nil)
    }

    @Test func inboxWaitsAreClampedForOpenCode() {
        #expect(RuntimeCoordinator.inboxWait(requested: 300, kind: .opencode) == 240)
        #expect(RuntimeCoordinator.inboxWait(requested: 30, kind: .opencode) == 30)
        #expect(RuntimeCoordinator.inboxWait(requested: 300, kind: .claude) == 300)
        #expect(RuntimeCoordinator.inboxWait(requested: 300, kind: .codex) == 300)
        #expect(RuntimeCoordinator.inboxWait(requested: 300, kind: nil) == 300)
    }

    @Test func runtimeLaunchPassesTheConfigurationLayerAndAdoptsTheSession() async throws {
        let fixture = try await LaunchFixture.make(kind: .opencode); defer { fixture.cleanup() }
        await fixture.runtime.setEndpoint(port: 4242)
        var request = fixture.request; request.coordinationEnabled = true; request.task = "Say hi"
        let launched = try await fixture.runtime.launch(request)
        #expect(launched.nativeConversationID == nil, "OpenCode names its own session")
        try await fixture.wait { FileManager.default.fileExists(atPath: fixture.path("launch-record").path) }
        let record = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: fixture.path("launch-record")))
        #expect(record["argv"] == .array([.string("--prompt"), .string("Say hi")]))
        #expect(record["cwd"].string == Paths.canonical(fixture.root.path))
        let environment = record["env"]
        #expect(environment["OPENCODE_CONFIG_DIR"].string == Paths.canonical(fixture.root.path))
        #expect(environment["CHAUFFEUR_SESSION_ID"].string == launched.id.uuidString && environment["CHAUFFEUR_CTL"].string != nil)
        #expect(environment["CHAUFFEUR_SESSION_TOKEN"].string != nil && environment["CHAUFFEUR_SOCKET"].string != nil)
        let content = try JSONCoding.decode(JSONValue.self, from: Data(try #require(environment["OPENCODE_CONFIG_CONTENT"].string).utf8))
        let plugin = try #require(content["plugin"].array.first?.string.flatMap(URL.init(string:)))
        #expect(plugin.path == fixture.path("plugins/chauffeur-opencode.js").path && FileManager.default.fileExists(atPath: plugin.path))
        #expect(content["mcp"]["chauffeur"]["url"].string == "http://127.0.0.1:4242/mcp")

        let token = try String(contentsOf: fixture.path("probe-token"), encoding: .utf8)
        let conversation = "ses_0123456789abcdefghijABCDEF"
        _ = try await fixture.runtime.handle(IPCRequest("event", params: .object(["token": .string(token), "event": .string("session-start"), "nativeConversationID": .string(conversation), "hookEvent": .string("SessionStart"), "source": .string("startup")])))
        #expect(try await fixture.session().nativeConversationID == conversation)
        // A later root or child ID never replaces it.
        _ = try await fixture.runtime.handle(IPCRequest("event", params: .object(["token": .string(token), "event": .string("session-start"), "nativeConversationID": .string("ses_ZZZZZZZZZZZZZZZZZZZZZZZZZZ"), "hookEvent": .string("SessionStart"), "source": .string("startup")])))
        #expect(try await fixture.session().nativeConversationID == conversation)

        let discovered = try await fixture.runtime.callTool(token: token, name: "chauffeur_discover", arguments: .object([:]))
        #expect(discovered["capabilities"]["waitCommand"] == .null && discovered["capabilities"]["resultWake"] == .bool(false)
            && discovered["capabilities"]["pluginWait"] == .bool(true))
        #expect(discovered["capabilities"]["inboxReminders"] == .bool(true))
        // OpenCode shows `<server>_<tool>`, so its tools are listed without Chauffeur's prefix.
        #expect(await fixture.runtime.exposesShortToolNames(token: token))
        #expect(await !fixture.runtime.exposesShortToolNames(token: "not-a-token"))
        _ = try await fixture.stop()
    }
}

/// Drives the built `chauffeurctl` the way the OpenCode plugin does.
struct OpenCodeHookCommandTests {
    private final class Marker {}
    private var ctl: URL? {
        let url = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("chauffeurctl")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    private func run(_ ctl: URL, _ arguments: [String], input: String, environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = ctl; process.arguments = arguments; process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    @Test func inboxHookAnswersThePluginContract() async throws {
        let ctl = try #require(ctl, "chauffeurctl must be built next to the test bundle")
        let fixture = try await LaunchFixture.make(kind: .opencode); defer { fixture.cleanup() }
        let server = try IPCServer(root: fixture.root, runtime: fixture.runtime); server.start()
        let launched = try await fixture.runtime.launch(fixture.request)
        let token = try String(contentsOf: fixture.path("probe-token"), encoding: .utf8)
        let environment = ["CHAUFFEUR_SESSION_TOKEN": token, "CHAUFFEUR_SOCKET": fixture.path("runtime/runtime.sock").path]
        let conversation = "ses_0123456789abcdefghijABCDEF"
        let stop = ["inbox-hook", "--provider", "opencode", "--report-stop"]
        func hook(_ event: String, _ extra: String = "", arguments: [String]? = nil) throws -> JSONValue? {
            let result = try run(ctl, arguments ?? stop, input: #"{"session_id":"\#(conversation)","hook_event_name":"\#(event)"\#(extra)}"#, environment: environment)
            #expect(result.status == 0 && (result.output.isEmpty || result.output.hasSuffix("}\n")))
            return result.output.isEmpty ? nil : try JSONCoding.decode(JSONValue.self, from: Data(result.output.utf8))
        }
        func state() async throws -> SessionState { try await fixture.session().state }

        // The plugin's session-start names the conversation through the ctl.
        let started = try run(ctl, ["event", "--session", launched.id.uuidString, "session-start"], input: #"{"session_id":"\#(conversation)","hook_event_name":"SessionStart","source":"startup"}"#, environment: environment)
        #expect(started.status == 0)
        #expect(try await fixture.session().nativeConversationID == conversation)
        _ = try run(ctl, ["event", "--session", launched.id.uuidString, "running"], input: #"{"session_id":"\#(conversation)"}"#, environment: environment)
        #expect(try await state() == .running)

        #expect(try hook("Stop", #","stop_hook_active":false"#) == .object(["block": .bool(false), "text": .null, "waitForWorkers": .bool(false)]))
        #expect(try await state() == .turnFinished)

        let peer = LedgerTests().session(project: launched.projectID, group: launched.groupID)
        try await fixture.runtime.ledger.register(peer)
        let sender = try await fixture.runtime.ledger.authenticate(fixture.runtime.ledger.issueGrant(sessionID: peer.id))
        _ = try await fixture.runtime.ledger.send(caller: sender, recipientID: launched.id, body: "Never in hook output", retryKey: "one")
        let tool = try #require(try hook("PostToolUse", arguments: ["inbox-hook", "--provider", "opencode"]))
        #expect(tool == .object(["block": .bool(false), "text": .string(InboxHintFormatter.text(InboxHintSummary(count: 1))), "waitForWorkers": .bool(false)]))
        #expect(try hook("PostToolUse", arguments: ["inbox-hook", "--provider", "opencode"])?["text"] == .null, "Each message is mentioned once")

        _ = try run(ctl, ["event", "--session", launched.id.uuidString, "running"], input: #"{"session_id":"\#(conversation)"}"#, environment: environment)
        _ = try await fixture.runtime.ledger.send(caller: sender, recipientID: launched.id, body: "Second", retryKey: "two")
        let blocked = try #require(try hook("Stop", #","stop_hook_active":false"#))
        #expect(blocked["block"] == .bool(true) && blocked["text"].string == InboxHintFormatter.text(InboxHintSummary(count: 1)))
        #expect(try await state() == .running, "A blocked Stop is not a finished turn")
        #expect(try hook("Stop", #","stop_hook_active":true"#)?["block"] == .bool(false))
        #expect(try await state() == .turnFinished, "The continuation ends the turn")

        // A coordinator with an open worker is told to wait, and gets no completion notice.
        _ = try run(ctl, ["event", "--session", launched.id.uuidString, "running"], input: #"{"session_id":"\#(conversation)"}"#, environment: environment)
        _ = try await fixture.runtime.handle(IPCRequest("markRead", params: .object(["sessionID": .string(launched.id.uuidString)])))
        let caller = try await fixture.runtime.ledger.authenticate(token)
        let (delegation, _) = try await fixture.runtime.ledger.reserveDelegation(caller: caller, task: "Work", presetID: UUID(), folderID: UUID(), shareCheckout: true, retryKey: "worker", limit: 4)
        #expect(await fixture.runtime.hasOpenWorkers(launched.id))
        _ = try await fixture.runtime.ledger.send(caller: sender, recipientID: launched.id, body: "Third", retryKey: "three")
        #expect(try hook("Stop", #","stop_hook_active":false"#)?["waitForWorkers"] == .bool(false), "A blocked Stop does not wait yet")
        let waiting = try #require(try hook("Stop", #","stop_hook_active":true"#))
        #expect(waiting == .object(["block": .bool(false), "text": .null, "waitForWorkers": .bool(true)]))
        let finished = try await fixture.session()
        #expect(finished.state == .turnFinished && !finished.unread)
        // When the waiter can't start or stops without work, the plugin reports the turn finished again, as finished work.
        _ = try run(ctl, ["event", "--session", launched.id.uuidString, "turn-finished"], input: #"{"session_id":"\#(conversation)"}"#, environment: environment)
        let fallback = try await fixture.session()
        #expect(fallback.state == .turnFinished && fallback.unread)

        var closed = delegation; closed.closureOutcome = "accepted"
        try await fixture.runtime.ledger.updateDelegation(closed)
        #expect(!(await fixture.runtime.hasOpenWorkers(launched.id)))
        #expect(try hook("Stop", #","stop_hook_active":false"#)?["waitForWorkers"] == .bool(false))

        // Claude's output is unchanged by the new field.
        let claude = try run(ctl, ["inbox-hook", "--provider", "claude"], input: #"{"session_id":"\#(conversation)","hook_event_name":"Stop"}"#, environment: environment)
        #expect(claude.status == 0 && claude.output.isEmpty)
        _ = try await fixture.stop()
    }

    @Test func thePluginWaitsOnlyForWorkersThatMayStillReport() {
        let project = UUID(), group = UUID()
        var worker = LedgerTests().session(project: project, group: group, parent: UUID())
        var item = Delegation(scope: GroupScope(projectID: project, groupID: group), parentID: worker.parentID!, childID: worker.id, task: "Work", presetID: UUID(), folderID: UUID(), shareCheckout: true)
        item.state = .running
        #expect(RuntimeCoordinator.isOpenWorker(item, child: nil), "Not launched yet")
        for state in [SessionState.starting, .activityUnknown, .running, .needsAttention] {
            worker.state = state
            #expect(RuntimeCoordinator.isOpenWorker(item, child: worker), "\(state)")
        }
        // Idle without a report for this turn (e.g. a follow-up it answered in text): it will not report.
        worker.state = .turnFinished
        #expect(!RuntimeCoordinator.isOpenWorker(item, child: worker))
        worker.state = .exited
        #expect(!RuntimeCoordinator.isOpenWorker(item, child: worker))
        worker.state = .running; item.state = .resultReported
        #expect(!RuntimeCoordinator.isOpenWorker(item, child: worker))
        item.state = .running; item.closureOutcome = "accepted"
        #expect(!RuntimeCoordinator.isOpenWorker(item, child: worker))
    }

    @Test func waitForWorkPrintsJSONForThePlugin() throws {
        let ctl = try #require(ctl)
        let result = try run(ctl, ["wait-for-work", "--json"], input: "", environment: [:])
        #expect(result.status == 1)
        let value = try JSONCoding.decode(JSONValue.self, from: Data(result.output.utf8))
        #expect(value["reason"] == .string("ended") && value["text"].string?.hasPrefix("Chauffeur:") == true)
        let plain = try run(ctl, ["wait-for-work"], input: "", environment: [:])
        #expect(plain.output == "Chauffeur: wait-for-work must run inside a Chauffeur agent session.\n")
    }
}
