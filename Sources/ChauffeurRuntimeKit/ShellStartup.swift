import Foundation
import ChauffeurCore

/// Keep team selection after zsh's login files, which commonly export a personal
/// CODEX_HOME. Source the user's files normally; never edit them. Other shells
/// receive the same child environment using their native startup behavior.
/// Named directories (`~name`) are defined after the user's `.zshrc`.
enum ShellStartup {
    static func isZsh(_ executable: String) -> Bool { URL(fileURLWithPath: executable).lastPathComponent == "zsh" }
    /// The dimmed help at the top of a new shell: the team's exports, then the
    /// checkout variables, then any named directories zsh defines for them.
    static func preamble(exports: [String: String], checkout: [String: String], namedDirectories: [String: String]) -> String? {
        let names = namedDirectories.keys.sorted().map { "~" + $0 }
        let lines = [ShellAgentEnvironment.exportCommand(exports), ShellAgentEnvironment.exportCommand(checkout),
                     names.isEmpty ? nil : "# zsh: cd " + names.joined(separator: " or cd ")].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    static func environment(executable: String, environment: [String: String], exports: [String: String], namedDirectories: [String: String] = [:], directory: URL) throws -> [String: String] {
        guard isZsh(executable), !exports.isEmpty || !namedDirectories.isEmpty else { return environment }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let apply = ShellAgentEnvironment.exportCommand(exports) ?? ""
        let wrapper = ShellAgentEnvironment.shellQuoted(directory.path)
        let names = namedDirectories.sorted { $0.key < $1.key }.map { "hash -d \($0.key)=\(ShellAgentEnvironment.shellQuoted($0.value))" }.joined(separator: "\n")
        let scripts = [
            ".zshenv": """
            unset ZDOTDIR
            if [[ -r "$HOME/.zshenv" ]]; then source "$HOME/.zshenv"; fi
            _chauffeur_user_zdotdir="${ZDOTDIR:-$HOME}"
            export ZDOTDIR=\(wrapper)
            \(apply)
            """,
            ".zprofile": """
            ZDOTDIR="$_chauffeur_user_zdotdir"
            if [[ -r "$ZDOTDIR/.zprofile" ]]; then source "$ZDOTDIR/.zprofile"; fi
            _chauffeur_user_zdotdir="${ZDOTDIR:-$HOME}"
            export ZDOTDIR=\(wrapper)
            \(apply)
            """,
            ".zshrc": """
            ZDOTDIR="$_chauffeur_user_zdotdir"
            # macOS /etc/zshrc derives its default history path from ZDOTDIR,
            # which still points at our wrapper while global startup files run.
            # Repair only that generated default, before user history overrides.
            if [[ "$HISTFILE" == \(wrapper)/.zsh_history ]]; then
                HISTFILE="$ZDOTDIR/.zsh_history"
            fi
            if [[ -r "$ZDOTDIR/.zshrc" ]]; then source "$ZDOTDIR/.zshrc"; fi
            _chauffeur_user_zdotdir="${ZDOTDIR:-$HOME}"
            export ZDOTDIR=\(wrapper)
            \(apply)
            \(names)
            """,
            ".zlogin": """
            ZDOTDIR="$_chauffeur_user_zdotdir"
            if [[ -r "$ZDOTDIR/.zlogin" ]]; then source "$ZDOTDIR/.zlogin"; fi
            unset _chauffeur_user_zdotdir
            \(apply)
            """
        ]
        for (name, contents) in scripts {
            let path = directory.appendingPathComponent(name)
            try Data((contents + "\n").utf8).write(to: path, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        var result = environment; result["ZDOTDIR"] = directory.path
        return result
    }
}
