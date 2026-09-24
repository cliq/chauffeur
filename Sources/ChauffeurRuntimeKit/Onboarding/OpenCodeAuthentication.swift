import Foundation
import ChauffeurCore

/// OpenCode has no single account: it is ready when `opencode models` lists
/// any model. Its hosted `opencode/*` models are always listed (V9).
public struct OpenCodeAuthentication<Runner: SetupCommandRunning>: AgentAuthentication {
    public static var providersURL: URL { URL(string: "https://opencode.ai/docs/providers/")! }
    private let runner: Runner

    public init(runner: Runner) { self.runner = runner }

    public func loginCommand(context: AuthenticationContext) async throws -> SetupCommand {
        guard context.kind == .opencode else {
            throw ChauffeurError("wrong_agent", "OpenCode authentication received a different agent kind")
        }
        return AuthenticationSupport.command(context, arguments: ["auth", "login"])
    }

    public func status(context: AuthenticationContext) async -> SetupAuthStatus {
        guard context.kind == .opencode else { return AuthenticationSupport.unavailable("This authentication adapter only supports OpenCode.") }
        do {
            let result = try await runner.run(AuthenticationSupport.command(context, arguments: ["models"]), timeout: 30, outputLimit: 256 * 1024)
            guard result.status == 0 else {
                let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).last.map { " \(String($0).prefix(300))" } ?? ""
                return AuthenticationSupport.unavailable("OpenCode could not list models.\(detail)")
            }
            let models = OpenCodeIntegration.parseModels(result.output)
            guard !models.isEmpty else {
                return SetupAuthStatus(phase: .signInRequired, checkedAt: Date(), message: "No models configured. Add a provider: \(Self.providersURL.absoluteString)")
            }
            let hostedOnly = models.allSatisfy { $0.hasPrefix("opencode/") }
            let message = hostedOnly
                ? "Only OpenCode's free hosted models are available. To add local or cloud providers, see \(Self.providersURL.absoluteString)"
                : "\(models.count) models available."
            return SetupAuthStatus(phase: .connected, method: hostedOnly ? "OpenCode hosted models" : "Configured providers", checkedAt: Date(), message: message)
        } catch {
            if let chauffeur = error as? ChauffeurError, chauffeur.code == "command_timeout" {
                return AuthenticationSupport.unavailable("OpenCode did not list models in time. Check the executable and try again.")
            }
            return AuthenticationSupport.unavailable("Could not run OpenCode's model listing. Check the executable and try again.")
        }
    }
}

public extension OpenCodeAuthentication where Runner == ProcessSetupCommandRunner {
    init() { self.init(runner: ProcessSetupCommandRunner()) }
}
