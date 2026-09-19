import Foundation
import ChauffeurCore

public struct ClaudeAuthentication<Runner: SetupCommandRunning>: AgentAuthentication {
    private let runner: Runner

    public init(runner: Runner) { self.runner = runner }

    public func loginCommand(context: AuthenticationContext) async throws -> SetupCommand {
        guard context.kind == .claude else {
            throw ChauffeurError("wrong_agent", "Claude authentication received a different agent kind")
        }
        return AuthenticationSupport.command(context, arguments: ["auth", "login"])
    }

    public func status(context: AuthenticationContext) async -> SetupAuthStatus {
        guard context.kind == .claude else { return AuthenticationSupport.unavailable("This authentication adapter only supports Claude Code.") }
        do {
            let help = try await runner.run(AuthenticationSupport.command(context, arguments: ["auth", "status", "--help"]), timeout: AuthenticationSupport.timeout, outputLimit: AuthenticationSupport.outputLimit)
            guard help.status == 0, !help.outputTruncated, help.error.isEmpty,
                  help.output.contains("--json") else {
                return AuthenticationSupport.unavailable("This Claude Code version does not expose the supported JSON authentication status command. Update Claude Code and recheck.")
            }
            let result = try await runner.run(AuthenticationSupport.command(context, arguments: ["auth", "status", "--json"]), timeout: AuthenticationSupport.timeout, outputLimit: AuthenticationSupport.outputLimit)
            guard !result.outputTruncated, result.error.isEmpty,
                  let data = result.output.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data),
                  let object = decoded as? [String: Any],
                  let loggedIn = object["loggedIn"] as? Bool,
                  let authMethod = object["authMethod"] as? String else {
                return AuthenticationSupport.unavailable("Claude Code returned an unsupported authentication status. Update Claude Code and recheck.")
            }
            if let reportedDirectory = object["configDirectory"] as? String,
               Paths.canonical(reportedDirectory) != Paths.canonical(context.configurationPath) {
                return AuthenticationSupport.unavailable("Claude Code reported authentication from a different configuration directory. Check the selected folder and recheck.")
            }
            if result.status == 1, loggedIn == false, authMethod == "none" {
                return AuthenticationSupport.signInRequired()
            }
            guard result.status == 0, loggedIn, authMethod != "none" else {
                return AuthenticationSupport.unavailable("Claude Code could not verify authentication for this configuration.")
            }
            guard let reportedDirectory = object["configDirectory"] as? String,
                  Paths.canonical(reportedDirectory) == Paths.canonical(context.configurationPath) else {
                return AuthenticationSupport.unavailable("This Claude Code version does not identify the signed-in configuration folder. Update Claude Code and recheck.")
            }
            let email = (object["email"] as? String) ?? (object["accountEmail"] as? String)
            let organization = (object["organizationName"] as? String) ?? (object["orgName"] as? String)
            return AuthenticationSupport.connected(method: authMethod, email: email, organization: organization)
        } catch {
            return AuthenticationSupport.unavailable(AuthenticationSupport.failureMessage(error, agent: "Claude Code"))
        }
    }
}

public extension ClaudeAuthentication where Runner == ProcessSetupCommandRunner {
    init() { self.init(runner: ProcessSetupCommandRunner()) }
}
