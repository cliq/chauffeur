import Foundation
import ChauffeurCore

/// Pi's provider-neutral auth check requires a provider name. Setup instead
/// inspects the selected profile's credential records without resolving keys,
/// running credential commands, refreshing OAuth, or exposing secret values.
public struct PiAuthentication: AgentAuthentication {
    public init() {}

    public func loginCommand(context: AuthenticationContext) async throws -> SetupCommand {
        guard context.kind == .pi else { throw ChauffeurError("wrong_agent", "This adapter only supports Pi") }
        // `/login` is an interactive Pi command. Passing it as an argument would
        // submit it as the initial user prompt rather than execute the command.
        return AuthenticationSupport.command(context, arguments: [])
    }

    public func status(context: AuthenticationContext) async -> SetupAuthStatus {
        guard context.kind == .pi else { return AuthenticationSupport.unavailable("This adapter only supports Pi.") }
        let path = URL(fileURLWithPath: context.configurationPath).appendingPathComponent("auth.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return AuthenticationSupport.signInRequired("Open Pi and enter /login to configure a provider in this Pi home.")
        }
        guard let data = try? Data(contentsOf: path),
              let document = try? JSONSerialization.jsonObject(with: data),
              let records = document as? [String: Any] else {
            return AuthenticationSupport.unavailable("Pi's credential file could not be read.")
        }
        guard records.values.allSatisfy(Self.isValidCredential) else {
            return AuthenticationSupport.unavailable("Pi's credential file contains an invalid credential record.")
        }
        guard records.values.contains(where: Self.isConfiguredCredential) else {
            return AuthenticationSupport.signInRequired("Open Pi and enter /login to configure a provider in this Pi home.")
        }
        return SetupAuthStatus(
            phase: .connected,
            method: "Pi credentials",
            checkedAt: Date(),
            message: "Local Pi credentials found. Account access, expiry, and quota were not tested."
        )
    }

    private static func isConfiguredCredential(_ value: Any) -> Bool {
        guard let credential = value as? [String: Any], let type = credential["type"] as? String else { return false }
        switch type {
        case "api_key": return nonempty(credential["key"]) || hasConfiguredEnvironment(credential["env"])
        case "oauth": return nonempty(credential["access"]) || nonempty(credential["refresh"])
        default: return false
        }
    }

    /// Mirrors Pi 0.87's `ReadOnlyAuthStorage` schema without resolving stored
    /// config values. One malformed provider invalidates the complete file.
    private static func isValidCredential(_ value: Any) -> Bool {
        guard let credential = value as? [String: Any], let type = credential["type"] as? String else { return false }
        switch type {
        case "api_key":
            let validKey = credential["key"] == nil || credential["key"] is String
            let validEnvironment: Bool
            if credential["env"] == nil {
                validEnvironment = true
            } else if let environment = credential["env"] as? [String: Any] {
                validEnvironment = environment.values.allSatisfy { $0 is String }
            } else {
                validEnvironment = false
            }
            return validKey && validEnvironment
        case "oauth":
            guard credential["access"] is String, credential["refresh"] is String,
                  let expires = credential["expires"] as? NSNumber,
                  CFGetTypeID(expires) != CFBooleanGetTypeID() else { return false }
            return expires.doubleValue.isFinite
        default:
            return false
        }
    }

    private static func nonempty(_ value: Any?) -> Bool {
        guard let string = value as? String else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasConfiguredEnvironment(_ value: Any?) -> Bool {
        guard let environment = value as? [String: Any] else { return false }
        return environment.values.contains(where: nonempty)
    }
}
