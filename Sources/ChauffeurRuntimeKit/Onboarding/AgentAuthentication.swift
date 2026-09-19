import Foundation
import ChauffeurCore

public struct SetupCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var directory: String
    public var environment: [String: String]

    public init(executable: String, arguments: [String], directory: String, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }
}

public struct AuthenticationContext: Equatable, Sendable {
    public var kind: CLIKind
    public var executable: String
    public var configurationPath: String
    public var baseEnvironment: [String: String]
    public var workingDirectory: String

    public init(kind: CLIKind, executable: String, configurationPath: String, baseEnvironment: [String: String], workingDirectory: String) {
        self.kind = kind
        self.executable = executable
        self.configurationPath = configurationPath
        self.baseEnvironment = baseEnvironment
        self.workingDirectory = workingDirectory
    }
}

public protocol SetupCommandRunning: Sendable {
    func run(_ command: SetupCommand, timeout: TimeInterval, outputLimit: Int) async throws -> CommandResult
}

public struct ProcessSetupCommandRunner: SetupCommandRunning {
    public init() {}
    public func run(_ command: SetupCommand, timeout: TimeInterval, outputLimit: Int) async throws -> CommandResult {
        try await ProcessRunner.run(
            command.executable,
            command.arguments,
            directory: command.directory,
            environment: command.environment,
            timeout: timeout,
            outputLimit: outputLimit
        )
    }
}

public protocol AgentAuthentication: Sendable {
    func loginCommand(context: AuthenticationContext) async throws -> SetupCommand
    func status(context: AuthenticationContext) async -> SetupAuthStatus
}

enum AuthenticationSupport {
    static let timeout: TimeInterval = 8
    static let outputLimit = 64 * 1024

    static func command(_ context: AuthenticationContext, arguments: [String]) -> SetupCommand {
        SetupCommand(
            executable: context.executable,
            arguments: arguments,
            directory: Paths.canonical(context.workingDirectory),
            environment: SetupEnvironment.make(base: context.baseEnvironment, kind: context.kind, directory: context.configurationPath)
        )
    }

    static func unavailable(_ message: String) -> SetupAuthStatus {
        SetupAuthStatus(phase: .unableToVerify, checkedAt: Date(), message: message)
    }

    static func signInRequired(_ message: String = "The CLI reports that this configuration is not signed in.") -> SetupAuthStatus {
        SetupAuthStatus(phase: .signInRequired, checkedAt: Date(), message: message)
    }

    static func connected(method: String?, email: String? = nil, organization: String? = nil) -> SetupAuthStatus {
        SetupAuthStatus(
            phase: .connected,
            email: nonempty(email),
            organization: nonempty(organization),
            method: nonempty(method),
            checkedAt: Date(),
            message: "Signed in according to the CLI. Account access and quota were not tested."
        )
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func failureMessage(_ error: Error, agent: String) -> String {
        if let chauffeur = error as? ChauffeurError, chauffeur.code == "command_timeout" {
            return "\(agent) did not return authentication status in time. Check the executable and try again."
        }
        return "Could not run \(agent)'s authentication status command. Check the executable and try again."
    }
}
