import Foundation
import Testing
import ChauffeurCore
@testable import ChauffeurRuntimeKit

struct OpenCodeIntegrationTests {
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
}
