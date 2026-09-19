import Foundation

/// Constructs the environment shared by setup login/status commands and later
/// agent launches. It deliberately carries no Chauffeur session grants.
public enum SetupEnvironment {
    public static func make(base: [String: String], kind: CLIKind, directory: String) -> [String: String] {
        var result = LaunchPolicy.sanitizedEnvironment(base: base)
        let profile = Paths.canonical(directory)
        switch kind {
        case .codex:
            result["CODEX_HOME"] = profile
        case .claude:
            result["CLAUDE_CONFIG_DIR"] = profile
        case .shell:
            break
        }
        result["TERM"] = "xterm-256color"
        result["COLORTERM"] = "truecolor"
        return result
    }
}
