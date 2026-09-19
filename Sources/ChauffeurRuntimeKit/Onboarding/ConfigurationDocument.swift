import ChauffeurCore
import Foundation
import TOMLKit

public enum ConfigurationDocument {
    private static let secretFragments = ["token", "secret", "password", "credential", "api_key", "apikey", "auth"]

    public static func claudeJSON(_ input: Data, categories: Set<CopyCategory>) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw ConfigurationMigrationError.unsupportedFile("Claude settings must contain a JSON object.")
        }
        let preferenceKeys: Set<String> = [
            "model", "effortLevel", "alwaysThinkingEnabled", "language", "outputStyle",
            "permissions", "includeCoAuthoredBy", "cleanupPeriodDays", "statusLine",
            "fileSuggestion", "respectGitignore", "autoUpdatesChannel", "forceLoginMethod",
            "forceLoginOrgUUID", "companyAnnouncements", "plansDirectory", "spinnerTipsEnabled",
            "prefersReducedMotion", "teammateMode", "attribution", "sandbox"
        ]
        let hooksKeys: Set<String> = ["hooks"]
        let connectionKeys: Set<String> = ["mcpServers", "mcp"]
        let pluginKeys: Set<String> = ["enabledPlugins", "extraKnownMarketplaces", "pluginConfig"]
        var output: [String: Any] = [:]
        for (key, value) in root {
            let selected = (categories.contains(.preferences) && preferenceKeys.contains(key))
                || (categories.contains(.hooks) && hooksKeys.contains(key))
                || (categories.contains(.connections) && connectionKeys.contains(key))
                || (categories.contains(.plugins) && pluginKeys.contains(key))
            if selected, let clean = sanitizedJSON(value, key: key) { output[key] = clean }
        }
        return try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func codexTOML(_ input: Data, categories: Set<CopyCategory>) throws -> Data {
        let parsed = try TOMLTable(string: String(decoding: input, as: UTF8.self))
        let preferenceKeys: Set<String> = [
            "model", "model_provider", "model_reasoning_effort", "model_reasoning_summary",
            "model_verbosity", "approval_policy", "sandbox_mode", "sandbox_workspace_write",
            "web_search", "personality", "features", "notices", "profiles", "projects",
            "project_doc_max_bytes", "project_doc_fallback_filenames", "hide_agent_reasoning",
            "show_raw_agent_reasoning", "disable_response_storage", "tool_output_token_limit",
            "tui", "shell_environment_policy", "model_providers"
        ]
        let output = TOMLTable()
        for key in parsed.keys {
            let selected = (categories.contains(.preferences) && preferenceKeys.contains(key))
                || (categories.contains(.connections) && key == "mcp_servers")
                || (categories.contains(.plugins) && key == "plugins")
            guard selected, !isSecretKey(key), let value = parsed[key], let clean = sanitizedTOML(value, key: key, categories: categories) else { continue }
            output[key] = clean
        }
        return Data(output.convert(to: .toml).utf8)
    }

    static func omittedClaudeKeys(_ input: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { return [] }
        let supported: Set<String> = [
            "model", "effortLevel", "alwaysThinkingEnabled", "language", "outputStyle", "permissions",
            "includeCoAuthoredBy", "cleanupPeriodDays", "statusLine", "fileSuggestion", "respectGitignore",
            "autoUpdatesChannel", "forceLoginMethod", "forceLoginOrgUUID", "companyAnnouncements",
            "plansDirectory", "spinnerTipsEnabled", "prefersReducedMotion", "teammateMode", "attribution",
            "sandbox", "hooks", "mcpServers", "mcp", "enabledPlugins", "extraKnownMarketplaces", "pluginConfig"
        ]
        return root.keys.filter { !supported.contains($0) || isSecretKey($0) || $0.lowercased() == "env" }.sorted()
    }

    static func omittedCodexKeys(_ input: Data) throws -> [String] {
        let table = try TOMLTable(string: String(decoding: input, as: UTF8.self))
        let supported: Set<String> = [
            "model", "model_provider", "model_reasoning_effort", "model_reasoning_summary", "model_verbosity",
            "approval_policy", "sandbox_mode", "sandbox_workspace_write", "web_search", "personality", "features",
            "notices", "profiles", "projects", "project_doc_max_bytes", "project_doc_fallback_filenames",
            "hide_agent_reasoning", "show_raw_agent_reasoning", "disable_response_storage", "tool_output_token_limit",
            "tui", "shell_environment_policy", "model_providers", "mcp_servers", "plugins"
        ]
        return table.keys.filter { !supported.contains($0) || isSecretKey($0) }.sorted()
    }

    static func repairPluginJSON(_ input: Data, source: URL, destination: URL) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: input)
        let repaired = repairJSONValue(root, source: source.standardizedFileURL.path, destination: destination.standardizedFileURL.path, key: nil)
        return try JSONSerialization.data(withJSONObject: repaired, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func isSecretKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return secretFragments.contains { normalized.contains($0) }
    }

    private static func sanitizedJSON(_ value: Any, key: String) -> Any? {
        if isSecretKey(key) || key.lowercased() == "env" { return nil }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, element in
                if let clean = sanitizedJSON(element.value, key: element.key) { result[element.key] = clean }
            }
        }
        if let array = value as? [Any] {
            return array.compactMap { item in
                if let dictionary = item as? [String: Any] { return sanitizedJSON(dictionary, key: "item") }
                return item
            }
        }
        return value
    }

    private static func sanitizedTOML(_ value: TOMLValueConvertible, key: String, categories: Set<CopyCategory>) -> TOMLValueConvertible? {
        let normalized = key.lowercased()
        if normalized == "mcp_servers", !categories.contains(.connections) { return nil }
        if normalized == "plugins", !categories.contains(.plugins) { return nil }
        if normalized == "hooks" || normalized == "notify" { return nil }
        if isSecretKey(key) || normalized == "env" || normalized == "env_key" || normalized.hasSuffix("_env_var")
            || normalized == "http_headers" || normalized == "env_http_headers" || normalized == "query_params" { return nil }
        if let table = value.table {
            let output = TOMLTable(inline: table.inline)
            for childKey in table.keys {
                if let child = table[childKey], let clean = sanitizedTOML(child, key: childKey, categories: categories) { output[childKey] = clean }
            }
            return output
        }
        if let array = value.array {
            let output = TOMLArray()
            for item in array {
                if let clean = sanitizedTOML(item, key: key, categories: categories) { output.append(clean) }
            }
            return output
        }
        return value.tomlValue
    }

    private static let pluginPathKeys: Set<String> = ["installLocation", "installPath", "sourcePath", "cachePath", "path"]

    private static func repairJSONValue(_ value: Any, source: String, destination: String, key: String?) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { repairJSONValue($0, source: source, destination: destination, key: nil) }
                .reduce(into: [String: Any]()) { result, element in
                    result[element.key] = repairJSONValue(dictionary[element.key]!, source: source, destination: destination, key: element.key)
                }
        }
        if let array = value as? [Any] { return array.map { repairJSONValue($0, source: source, destination: destination, key: key) } }
        guard let string = value as? String, let key, pluginPathKeys.contains(key) else { return value }
        if string == source { return destination }
        guard string.hasPrefix(source + "/") else { return string }
        let suffix = String(string.dropFirst(source.count + 1))
        return URL(fileURLWithPath: destination).appendingPathComponent(suffix).path
    }
}
