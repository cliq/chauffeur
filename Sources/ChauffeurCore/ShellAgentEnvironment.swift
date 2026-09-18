import Foundation

/// Configuration-directory variables a shell session inherits so that running an agent CLI by
/// hand inside it uses the same setup as the project's presets.
public enum ShellAgentEnvironment {
    public static func variableName(for kind: CLIKind) -> String? {
        switch kind {
        case .codex: return "CODEX_HOME"
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .shell: return nil
        }
    }

    /// Compatibility for unmigrated teams: first non-archived preset by name
    /// for each agent. Migrated teams read their configuration directly.
    public static func variables(presets: [AgentPreset], set: PresetSet) -> [String: String] {
        guard !set.archived else { return [:] }
        let candidates = presets.filter { $0.setID == set.id && !$0.archived && $0.kind.isAgent }
        var result: [String: String] = [:]
        for kind in CLIKind.allCases where kind.isAgent {
            guard let name = variableName(for: kind) else { continue }
            let ofKind = candidates.filter { $0.kind == kind }
            let chosen = ofKind.sorted(by: StoreSnapshot.agentOrder).first
            if let chosen, !chosen.configurationDirectory.isEmpty {
                result[name] = chosen.configurationDirectory
            }
        }
        return result
    }

    /// POSIX `export` lines the user can read and re-run, one variable per line, sorted by name.
    /// Returns nil when there is nothing to export.
    public static func exportCommand(_ variables: [String: String]) -> String? {
        guard !variables.isEmpty else { return nil }
        return variables.keys.sorted().map { "export \($0)=\(shellQuoted(variables[$0]!))" }.joined(separator: "\n")
    }

    /// Single-quoted so every character is literal; embedded quotes become `'\''`.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
