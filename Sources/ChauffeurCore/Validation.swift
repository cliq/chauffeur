import Foundation
import Darwin

public struct ChauffeurError: Error, Codable, Equatable, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var path: String?
    public init(_ code: String, _ message: String, path: String? = nil) { self.code = code; self.message = message; self.path = path }
    public var errorDescription: String? { path.map { "\(message) (\($0))" } ?? message }
}

public enum Validation {
    public static func require(_ condition: Bool, _ message: String) throws { if !condition { throw ChauffeurError("invalid", message) } }
    public static func name(_ value: String) throws {
        try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 240 && !value.contains("\0"), "Name must contain 1–240 characters")
    }
    public static func absolutePath(_ value: String) throws { try require(value.hasPrefix("/") && !value.contains("\0"), "Path must be absolute") }
    public static func unique<T: Hashable>(_ values: [T], field: String) throws { try require(Set(values).count == values.count, "Duplicate \(field)") }
}

public enum Paths {
    public static var applicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Chauffeur", isDirectory: true)
    }
    public static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        if let resolved = realpath(url.path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        if url.path == "/" { return "/" }
        // realpath also normalizes macOS /var -> /private/var aliases, unlike
        // Foundation's resolver. Preserve that identity for missing leaf paths.
        return URL(fileURLWithPath: canonical(url.deletingLastPathComponent().path)).appendingPathComponent(url.lastPathComponent).path
    }
    public static func directory(_ path: String) throws -> String {
        try Validation.absolutePath(path)
        let resolved = canonical(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ChauffeurError("missing_directory", "Directory is missing. Relink it before launching", path: path)
        }
        guard FileManager.default.isReadableFile(atPath: resolved), FileManager.default.isExecutableFile(atPath: resolved) else {
            throw ChauffeurError("inaccessible_directory", "Directory is not readable/searchable", path: path)
        }
        return resolved
    }
    public static func executable(_ value: String, environment: [String: String]) throws -> String {
        let candidates = value.contains("/") ? [value] : (environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin").split(separator: ":").map { "\($0)/\(value)" }
        if let candidate = candidates.map(canonical).first(where: { FileManager.default.isExecutableFile(atPath: $0) && (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) {
            return candidate
        }
        throw ChauffeurError("missing_executable", "Executable was not found or is not executable. Select its full path", path: value)
    }
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let parts = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return String((parts.isEmpty ? "untitled" : parts.joined(separator: "-")).prefix(64))
    }
}

public enum LaunchPolicy {
    // Start with the login environment, never an environment inherited from a
    // parent agent. Strip provider routing/auth and nested CLI session identity.
    public static let deniedPrefixes = ["CODEX_", "CLAUDE_", "CLAUDECODE", "OPENAI_", "ANTHROPIC_", "AZURE_OPENAI_", "CHAUFFEUR_", "AWS_", "GOOGLE_", "VERTEX_", "BEDROCK_"]
    public static let deniedNames: Set<String> = ["TMUX", "TMUX_PANE", "GOOGLE_APPLICATION_CREDENTIALS", "CLOUD_ML_REGION", "BASH_ENV", "ENV", "ZDOTDIR", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH"]
    public static func environment(base: [String: String], preset: AgentPreset, sessionID: UUID, token: String) throws -> [String: String] {
        let directory = try Paths.directory(preset.configurationDirectory)
        var result = base.filter { key, _ in !deniedNames.contains(key) && !deniedPrefixes.contains(where: key.hasPrefix) }
        result[preset.kind == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"] = directory
        result["CHAUFFEUR_SESSION_ID"] = sessionID.uuidString
        result["CHAUFFEUR_SESSION_TOKEN"] = token
        result["TERM"] = "xterm-256color"
        result["COLORTERM"] = "truecolor"
        return result
    }

    public static func validateAdditionalDirectories(_ paths: [String], preset: AgentPreset) throws {
        guard !paths.isEmpty, preset.kind == .codex else { return }
        let readOnly = preset.arguments.enumerated().contains { index, argument in
            argument == "--sandbox=read-only" || argument == "-s=read-only"
                || ((argument == "--sandbox" || argument == "-s") && preset.arguments.dropFirst(index + 1).first == "read-only")
        }
        guard !readOnly else {
            throw ChauffeurError("unsupported_directories", "Codex's read-only sandbox cannot add writable folders. Remove the additional folders or select workspace-write in the preset's launch arguments")
        }
    }

    public static func validateArguments(_ arguments: [String], kind: CLIKind) throws {
        let common: Set<String> = ["--", "--add-dir", "--worktree", "--resume", "--continue", "--session-id", "--fork-session", "--remote", "--remote-auth-token-env", "--cloud", "--teleport"]
        let codex: Set<String> = ["-C", "--cd", "-c", "--config", "--last", "--all"]
        let claude: Set<String> = ["-c", "-r", "-w", "--mcp-config", "--strict-mcp-config", "--settings", "--setting-sources", "--safe-mode", "--no-session-persistence", "--print", "-p", "--output-format", "--input-format", "--plugin-dir", "--plugin-url", "--environment", "--tmux"]
        let blocked = common.union(kind == .codex ? codex : claude)
        for argument in arguments {
            try Validation.require(!argument.contains("\0") && !argument.contains("\n"), "Arguments cannot contain NUL or newlines")
            let key = String(argument.split(separator: "=", maxSplits: 1).first ?? "")
            let shortConflict = (kind == .codex ? ["-C", "-c"] : ["-r", "-w"]).contains { key.hasPrefix($0) && key != $0 }
            guard !blocked.contains(key), !shortConflict else {
                throw ChauffeurError("managed_argument", "\(key) conflicts with Chauffeur-managed launch fields")
            }
        }
        // A conservative option/value grammar rejects CLI subcommands and task
        // positionals while preserving explicit native model/permission options.
        let takesValue: Set<String> = kind == .codex
            ? ["-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "--enable", "--disable", "--local-provider", "-i", "--image"]
            : ["--model", "--effort", "--permission-mode", "--agent", "--agents", "--append-system-prompt", "--system-prompt", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools", "--tools", "--name", "-n", "--fallback-model"]
        let flags: Set<String> = kind == .codex
            ? ["--search", "--no-alt-screen", "--oss", "--strict-config", "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox", "--yolo"]
            : ["--verbose", "--chrome", "--no-chrome", "--ide", "--disable-slash-commands", "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"]
        var index = 0
        while index < arguments.count {
            try Validation.require(!arguments[index].hasPrefix("—") && !arguments[index].hasPrefix("–"), "Replace the typographic dash at the start of an option with two hyphens (--)")
            let parts = arguments[index].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            if takesValue.contains(key) {
                if parts.count == 1 {
                    index += 1
                    try Validation.require(index < arguments.count && !arguments[index].hasPrefix("-"), "\(key) requires an explicit value")
                }
            } else {
                try Validation.require(flags.contains(key) && parts.count == 1, "Unsupported launch argument \(key). Use the dedicated launch fields or a supported native option")
            }
            index += 1
        }
    }
}
