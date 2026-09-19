import Foundation
import ChauffeurCore

public struct CodexAuthentication<Runner: SetupCommandRunning>: AgentAuthentication {
    private let runner: Runner

    public init(runner: Runner) { self.runner = runner }

    public func loginCommand(context: AuthenticationContext) async throws -> SetupCommand {
        guard context.kind == .codex else {
            throw ChauffeurError("wrong_agent", "Codex authentication received a different agent kind")
        }
        return AuthenticationSupport.command(context, arguments: ["login"])
    }

    public func status(context: AuthenticationContext) async -> SetupAuthStatus {
        guard context.kind == .codex else { return AuthenticationSupport.unavailable("This authentication adapter only supports Codex.") }
        do {
            let help = try await runner.run(AuthenticationSupport.command(context, arguments: ["login", "--help"]), timeout: AuthenticationSupport.timeout, outputLimit: AuthenticationSupport.outputLimit)
            guard help.status == 0, !help.outputTruncated,
                  help.output.contains("status") else {
                return AuthenticationSupport.unavailable("This Codex version does not expose the supported login status command. Update Codex and recheck.")
            }
            let result = try await runner.run(AuthenticationSupport.command(context, arguments: ["login", "status"]), timeout: AuthenticationSupport.timeout, outputLimit: AuthenticationSupport.outputLimit)
            guard !result.outputTruncated else {
                return AuthenticationSupport.unavailable("Codex returned incomplete authentication status. Recheck or sign in again.")
            }
            let stdout = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            // Codex 0.155 emits `login status` on stderr. Accept exactly one
            // stream so a warning or diagnostic can never be mistaken for the
            // affirmative status line.
            guard stdout.isEmpty != stderr.isEmpty else {
                return AuthenticationSupport.unavailable("Codex returned ambiguous authentication status. Recheck or sign in again.")
            }
            let line = stdout.isEmpty ? stderr : stdout
            if result.status == 1, line.caseInsensitiveCompare("Not logged in") == .orderedSame {
                return AuthenticationSupport.signInRequired()
            }
            guard result.status == 0 else {
                return AuthenticationSupport.unavailable("Codex could not verify authentication for this configuration.")
            }
            let prefix = "Logged in using "
            guard line.hasPrefix(prefix), line.count > prefix.count, !line.contains("\n") else {
                return AuthenticationSupport.unavailable("This Codex version returned an unsupported authentication status. Update Codex and recheck.")
            }
            let method = String(line.dropFirst(prefix.count))
            let supported = ["ChatGPT", "an API key", "API key"]
            guard supported.contains(method) else {
                return AuthenticationSupport.unavailable("Codex reported an authentication method this version of Chauffeur cannot verify.")
            }
            return AuthenticationSupport.connected(method: method)
        } catch {
            return AuthenticationSupport.unavailable(AuthenticationSupport.failureMessage(error, agent: "Codex"))
        }
    }
}

public extension CodexAuthentication where Runner == ProcessSetupCommandRunner {
    init() { self.init(runner: ProcessSetupCommandRunner()) }
}
