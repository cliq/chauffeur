import Foundation
import ChauffeurCore

/// Kimi has no auth-status command. Inspect local credentials without making
/// a model request or exposing their contents in setup diagnostics.
public struct KimiAuthentication: AgentAuthentication {
    public init() {}
    public func loginCommand(context: AuthenticationContext) async throws -> SetupCommand {
        guard context.kind == .kimi else { throw ChauffeurError("wrong_agent", "This adapter only supports Kimi Code") }
        return AuthenticationSupport.command(context, arguments: ["login"])
    }
    public func status(context: AuthenticationContext) async -> SetupAuthStatus {
        guard context.kind == .kimi else { return AuthenticationSupport.unavailable("This adapter only supports Kimi Code") }
        let path = URL(fileURLWithPath: context.configurationPath).appendingPathComponent("credentials/kimi-code.json")
        if let data = try? Data(contentsOf: path), let value = try? JSONCoding.decode(JSONValue.self, from: data),
           !(value["access_token"].string ?? "").isEmpty || !(value["refresh_token"].string ?? "").isEmpty {
            return SetupAuthStatus(phase: .connected, method: "Kimi Code credentials", checkedAt: Date(), message: "Local login credentials found. Account access and quota were not tested.")
        }
        do {
            let result = try await ProcessSetupCommandRunner().run(AuthenticationSupport.command(context, arguments: ["provider", "list", "--json"]), timeout: 8, outputLimit: 256 * 1024)
            guard result.status == 0, let value = try? JSONCoding.decode(JSONValue.self, from: Data(result.output.utf8)) else {
                return AuthenticationSupport.unavailable("Kimi Code could not read its provider configuration.")
            }
            if case .object(let providers) = value["providers"], providers.values.contains(where: {
                !($0["apiKey"].string ?? $0["api_key"].string ?? "").isEmpty
            }) {
                return SetupAuthStatus(phase: .connected, method: "Configured API key", checkedAt: Date(), message: "A provider API key is configured. Account access and quota were not tested.")
            }
            return AuthenticationSupport.signInRequired("Sign in with Kimi Code, or configure a provider in this Kimi home.")
        } catch { return AuthenticationSupport.unavailable("Could not inspect Kimi Code's provider configuration.") }
    }
}
