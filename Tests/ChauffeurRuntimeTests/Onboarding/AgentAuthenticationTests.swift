import Foundation
import Testing
@testable import ChauffeurCore
@testable import ChauffeurRuntimeKit

@Suite struct AgentAuthenticationTests {
    @Test func openCodeIsReadyWhenModelsAreListed() async throws {
        let runner = FakeAuthenticationRunner([.success(.init(status: 0, output: "opencode/big-pickle\nlocal/qwen3-14b\n", error: ""))])
        let adapter = OpenCodeAuthentication(runner: runner)
        let context = fixtureContext(kind: .opencode)
        let login = try await adapter.loginCommand(context: context)
        let status = await adapter.status(context: context)
        let commands = await runner.commands
        #expect(login.arguments == ["auth", "login"])
        #expect(login.environment["OPENCODE_CONFIG_DIR"] == "/profiles/work")
        #expect(commands.map(\.arguments) == [["models"]])
        #expect(commands.allSatisfy { $0.environment["OPENAI_API_KEY"] == nil })
        #expect(status.phase == .connected)
        #expect(status.message?.contains("2 models") == true)
    }

    @Test func openCodeHostedModelsOnlyAreReadyWithAProvidersNote() async {
        let runner = FakeAuthenticationRunner([.success(.init(status: 0, output: "opencode/big-pickle\nopencode/grok-code\n", error: ""))])
        let status = await OpenCodeAuthentication(runner: runner).status(context: fixtureContext(kind: .opencode))
        #expect(status.phase == .connected)
        #expect(status.message?.contains("free hosted models") == true)
        #expect(status.message?.contains("https://opencode.ai/docs/providers/") == true)
    }

    @Test func openCodeListingFailureIsNotReady() async {
        let failed = FakeAuthenticationRunner([.success(.init(status: 1, output: "", error: "Error: invalid config\n"))])
        let status = await OpenCodeAuthentication(runner: failed).status(context: fixtureContext(kind: .opencode))
        #expect(status.phase == .unableToVerify)
        #expect(status.message?.contains("invalid config") == true)
        let empty = FakeAuthenticationRunner([.success(.init(status: 0, output: "", error: ""))])
        #expect(await OpenCodeAuthentication(runner: empty).status(context: fixtureContext(kind: .opencode)).phase == .signInRequired)
        let missing = FakeAuthenticationRunner([.failure(ChauffeurError("missing_executable", "missing"))])
        #expect(await OpenCodeAuthentication(runner: missing).status(context: fixtureContext(kind: .opencode)).phase == .unableToVerify)
        #expect(await OpenCodeAuthentication(runner: missing).status(context: fixtureContext(kind: .codex)).phase == .unableToVerify)
    }

    @Test func codexUsesIsolatedProfileForLoginAndVerification() async throws {
        let runner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "Usage: codex login [OPTIONS] [COMMAND]\nCommands:\n  status  Show login status\n", error: "benign help warning")),
            .success(.init(status: 0, output: "", error: "Logged in using ChatGPT\n"))
        ])
        let adapter = CodexAuthentication(runner: runner)
        let context = fixtureContext(kind: .codex)
        let login = try await adapter.loginCommand(context: context)
        let status = await adapter.status(context: context)
        let commands = await runner.commands

        #expect(login.arguments == ["login"])
        #expect(login.environment["CODEX_HOME"] == "/profiles/work")
        #expect(login.environment["OPENAI_API_KEY"] == nil)
        #expect(status.phase == .connected)
        #expect(status.method == "ChatGPT")
        #expect(status.email == nil)
        #expect(commands.allSatisfy { $0.environment["CODEX_HOME"] == "/profiles/work" })
        #expect(commands.allSatisfy { $0.environment["OPENAI_API_KEY"] == nil })
    }

    @Test func codexAcceptsAPIKeySuffixWithoutRetainingCredentialText() async throws {
        let runner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "status", error: "")),
            .success(.init(status: 0, output: "", error: "Logged in using an API key - sk-fixture-sensitive\n"))
        ])
        let result = await CodexAuthentication(runner: runner).status(context: fixtureContext(kind: .codex))
        #expect(result.phase == .connected)
        #expect(result.method == "API key")
        #expect(!String(decoding: try JSONCoding.encode(result), as: UTF8.self).contains("sk-fixture-sensitive"))
    }

    @Test func claudeToleratesStderrNoticesWithValidDirectoryScopedJSON() async {
        let runner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "--json", error: "Update available\n")),
            .success(.init(status: 0, output: #"{"loggedIn":true,"authMethod":"oauth","configDirectory":"/profiles/work"}"#, error: "Update available\n"))
        ])
        let result = await ClaudeAuthentication(runner: runner).status(context: fixtureContext(kind: .claude))
        #expect(result.phase == .connected)
    }

    @Test func knownCodexNegativeRequiresSignIn() async {
        let runner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "status Show login status", error: "")),
            .success(.init(status: 1, output: "", error: "Not logged in\n"))
        ])
        let result = await CodexAuthentication(runner: runner).status(context: fixtureContext(kind: .codex))
        #expect(result.phase == .signInRequired)
    }

    @Test func unknownOrTruncatedCodexOutputNeverConnects() async {
        let unknown = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "status", error: "")),
            .success(.init(status: 0, output: "Authenticated somehow new", error: ""))
        ])
        #expect(await CodexAuthentication(runner: unknown).status(context: fixtureContext(kind: .codex)).phase == .unableToVerify)

        var truncated = CommandResult(status: 0, output: "Logged in using ChatGPT", error: "")
        truncated.outputTruncated = true
        let truncatedRunner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "status", error: "")), .success(truncated)
        ])
        #expect(await CodexAuthentication(runner: truncatedRunner).status(context: fixtureContext(kind: .codex)).phase == .unableToVerify)
    }

    @Test func claudeParsesOptionalIdentityWithoutReadingCredentialFiles() async throws {
        let runner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "--json Output as JSON", error: "")),
            .success(.init(status: 0, output: #"{"loggedIn":true,"authMethod":"oauth","email":"work@example.test","organizationName":"Acme","configDirectory":"/profiles/work"}"#, error: ""))
        ])
        let adapter = ClaudeAuthentication(runner: runner)
        let context = fixtureContext(kind: .claude)
        let login = try await adapter.loginCommand(context: context)
        let result = await adapter.status(context: context)

        #expect(login.arguments == ["auth", "login"])
        #expect(login.environment["CLAUDE_CONFIG_DIR"] == "/profiles/work")
        #expect(login.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
        #expect(result.phase == .connected, Comment(rawValue: result.message ?? "No status message"))
        #expect(result.email == "work@example.test")
        #expect(result.organization == "Acme")
        #expect(result.method == "oauth")
    }

    @Test func knownClaudeNegativeRequiresSignIn() async {
        let runner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "--json", error: "")),
            .success(.init(status: 1, output: #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty","configDirectory":"/profiles/work"}"#, error: ""))
        ])
        let result = await ClaudeAuthentication(runner: runner).status(context: fixtureContext(kind: .claude))
        #expect(result.phase == .signInRequired)
    }

    @Test func claudeRefusesStatusFromAnotherConfigurationDirectory() async {
        let runner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "--json", error: "")),
            .success(.init(status: 0, output: #"{"loggedIn":true,"authMethod":"oauth","configDirectory":"/profiles/personal"}"#, error: ""))
        ])
        let result = await ClaudeAuthentication(runner: runner).status(context: fixtureContext(kind: .claude))
        #expect(result.phase == .unableToVerify)
    }

    @Test func claudeCannotVerifyIdentityWhenOutputOmitsDirectory() async {
        let runner = FakeAuthenticationRunner([
            .success(.init(status: 0, output: "--json", error: "")),
            .success(.init(status: 0, output: #"{"loggedIn":true,"authMethod":"oauth"}"#, error: ""))
        ])
        let result = await ClaudeAuthentication(runner: runner).status(context: fixtureContext(kind: .claude))
        #expect(result.phase == .unableToVerify)
    }

    @Test func missingBinaryAndTimeoutAreActionableButNeverConnected() async {
        let missing = FakeAuthenticationRunner([.failure(ChauffeurError("missing_executable", "missing"))])
        let missingResult = await CodexAuthentication(runner: missing).status(context: fixtureContext(kind: .codex))
        #expect(missingResult.phase == .unableToVerify)
        #expect(missingResult.message?.contains("executable") == true)

        let timeout = FakeAuthenticationRunner([.failure(ChauffeurError("command_timeout", "late"))])
        let timeoutResult = await ClaudeAuthentication(runner: timeout).status(context: fixtureContext(kind: .claude))
        #expect(timeoutResult.phase == .unableToVerify)
        #expect(timeoutResult.message?.contains("in time") == true)
    }

    @Test func processRunnerUsesTheExplicitDirectoryWithAFakeCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-auth-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex-fixture")
        let profile = root.appendingPathComponent("profile").path
        let canonicalProfile = Paths.canonical(profile)
        let script = """
        #!/bin/sh
        if [ "$1 $2" = "login --help" ]; then
          printf 'status Show login status\\n'
          exit 0
        fi
        if [ "$1 $2" = "login status" ] && [ "$CODEX_HOME" = "\(canonicalProfile)" ] && [ -z "$OPENAI_API_KEY" ] && [ -z "$CHAUFFEUR_SESSION_TOKEN" ]; then
          printf 'Logged in using ChatGPT\\n' >&2
          exit 0
        fi
        printf 'unexpected context\\n'
        exit 9
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let context = AuthenticationContext(
            kind: .codex,
            executable: executable.path,
            configurationPath: profile,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "wrong", "CHAUFFEUR_SESSION_TOKEN": "wrong"],
            workingDirectory: root.path
        )

        let result = await CodexAuthentication().status(context: context)
        #expect(result.phase == .connected, Comment(rawValue: result.message ?? "No status message"))
    }
}

private func fixtureContext(kind: CLIKind) -> AuthenticationContext {
    AuthenticationContext(
        kind: kind,
        executable: kind == .codex ? "/fake/codex" : "/fake/claude",
        configurationPath: "/profiles/work",
        baseEnvironment: [
            "PATH": "/bin", "OPENAI_API_KEY": "wrong", "ANTHROPIC_API_KEY": "wrong",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/global", "CHAUFFEUR_SESSION_TOKEN": "wrong"
        ],
        workingDirectory: "/tmp"
    )
}

private actor FakeAuthenticationRunner: SetupCommandRunning {
    private var responses: [Result<CommandResult, Error>]
    private(set) var commands: [SetupCommand] = []
    init(_ responses: [Result<CommandResult, Error>]) { self.responses = responses }
    func run(_ command: SetupCommand, timeout: TimeInterval, outputLimit: Int) async throws -> CommandResult {
        commands.append(command)
        guard !responses.isEmpty else { throw ChauffeurError("fixture", "No fixture response") }
        return try responses.removeFirst().get()
    }
}
