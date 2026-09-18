import Foundation
import ChauffeurCore

/// Keep team selection after zsh's login files, which commonly export a personal
/// CODEX_HOME. Source the user's files normally; never edit them. Other shells
/// receive the same child environment using their native startup behavior.
enum ShellStartup {
    static func environment(executable: String, environment: [String: String], exports: [String: String], directory: URL) throws -> [String: String] {
        guard URL(fileURLWithPath: executable).lastPathComponent == "zsh", !exports.isEmpty else { return environment }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let apply = ShellAgentEnvironment.exportCommand(exports) ?? ""
        let wrapper = ShellAgentEnvironment.shellQuoted(directory.path)
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
            if [[ -r "$ZDOTDIR/.zshrc" ]]; then source "$ZDOTDIR/.zshrc"; fi
            _chauffeur_user_zdotdir="${ZDOTDIR:-$HOME}"
            export ZDOTDIR=\(wrapper)
            \(apply)
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
