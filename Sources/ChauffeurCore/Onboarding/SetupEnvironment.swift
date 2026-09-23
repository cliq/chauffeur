import Foundation

/// Constructs the environment shared by setup login/status commands and later
/// agent launches. It deliberately carries no Chauffeur session grants.
public enum SetupEnvironment {
    public static func make(base: [String: String], kind: CLIKind, directory: String) -> [String: String] {
        var result = LaunchPolicy.sanitizedEnvironment(base: base)
        result.merge(kind.provider?.environment(configurationDirectory: Paths.canonical(directory)) ?? [:]) { _, profile in profile }
        result["TERM"] = "xterm-256color"
        result["COLORTERM"] = "truecolor"
        return result
    }
}
