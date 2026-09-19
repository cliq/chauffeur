import ChauffeurCore
import Foundation
import TOMLKit

public enum ConfigurationDocument {
    struct SanitizedDocument {
        let data: Data
        let omittedPaths: [String]
    }

    private enum ValueContext { case ordinary, identifierMap, environment, environmentReferences, headers, queryParameters }

    public static func claudeJSON(_ input: Data, categories: Set<CopyCategory>) throws -> Data {
        try sanitizedClaudeJSON(input, categories: categories).data
    }

    static func sanitizedClaudeJSON(_ input: Data, categories: Set<CopyCategory>) throws -> SanitizedDocument {
        guard let root = try JSONSerialization.jsonObject(with: input) as? [String: Any] else {
            throw ConfigurationMigrationError.unsupportedFile("Claude settings must contain a JSON object.")
        }
        let preferenceKeys: Set<String> = [
            "model", "effortLevel", "alwaysThinkingEnabled", "language", "outputStyle", "permissions",
            "includeCoAuthoredBy", "cleanupPeriodDays", "statusLine", "fileSuggestion", "respectGitignore",
            "autoUpdatesChannel", "forceLoginMethod", "forceLoginOrgUUID", "companyAnnouncements",
            "plansDirectory", "spinnerTipsEnabled", "prefersReducedMotion", "teammateMode", "attribution", "sandbox"
        ]
        let hooksKeys: Set<String> = ["hooks"]
        let connectionKeys: Set<String> = ["mcpServers", "mcp"]
        let pluginKeys: Set<String> = ["enabledPlugins", "extraKnownMarketplaces", "pluginConfig"]
        let supported = preferenceKeys.union(hooksKeys).union(connectionKeys).union(pluginKeys)
        var output: [String: Any] = [:]
        var omittedPaths: [String] = []
        for (key, value) in root where !supported.contains(key) {
            appendJSONLeafPaths(value, path: key, to: &omittedPaths)
        }
        for (key, value) in root {
            let selected = (categories.contains(.preferences) && preferenceKeys.contains(key))
                || (categories.contains(.hooks) && hooksKeys.contains(key))
                || (categories.contains(.connections) && connectionKeys.contains(key))
                || (categories.contains(.plugins) && pluginKeys.contains(key))
            guard selected else { continue }
            if let clean = sanitizedJSON(value, key: key, path: key, context: .ordinary, omittedPaths: &omittedPaths) {
                output[key] = clean
            }
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return SanitizedDocument(data: data, omittedPaths: Array(Set(omittedPaths)).sorted())
    }

    public static func codexTOML(_ input: Data, categories: Set<CopyCategory>) throws -> Data {
        try sanitizedCodexTOML(input, categories: categories).data
    }

    static func sanitizedCodexTOML(_ input: Data, categories: Set<CopyCategory>) throws -> SanitizedDocument {
        let parsed = try TOMLTable(string: String(decoding: input, as: UTF8.self))
        let preferenceKeys: Set<String> = [
            "model", "model_provider", "model_reasoning_effort", "model_reasoning_summary", "model_verbosity",
            "approval_policy", "sandbox_mode", "sandbox_workspace_write", "web_search", "personality", "features",
            "notices", "profiles", "projects", "project_doc_max_bytes", "project_doc_fallback_filenames",
            "hide_agent_reasoning", "show_raw_agent_reasoning", "disable_response_storage", "tool_output_token_limit",
            "tui", "shell_environment_policy", "model_providers"
        ]
        let supported = preferenceKeys.union(["mcp_servers", "plugins", "marketplaces"])
        let output = TOMLTable()
        var omittedPaths: [String] = []
        for key in parsed.keys where !supported.contains(key) {
            if let value = parsed[key] { appendTOMLLeafPaths(value, path: key, to: &omittedPaths) }
        }
        for key in parsed.keys {
            let selected = (categories.contains(.preferences) && preferenceKeys.contains(key))
                || (categories.contains(.connections) && key == "mcp_servers")
                || (categories.contains(.plugins) && (key == "plugins" || key == "marketplaces"))
            guard selected, let value = parsed[key],
                  let clean = sanitizedTOML(value, key: key, path: key, context: .ordinary,
                                            categories: categories, omittedPaths: &omittedPaths) else { continue }
            output[key] = clean
        }
        return SanitizedDocument(data: Data(output.convert(to: .toml).utf8),
                                 omittedPaths: Array(Set(omittedPaths)).sorted())
    }

    static func omittedClaudeKeys(_ input: Data) throws -> [String] {
        try sanitizedClaudeJSON(input, categories: Set(CopyCategory.allCases)).omittedPaths
    }

    static func omittedCodexKeys(_ input: Data) throws -> [String] {
        try sanitizedCodexTOML(input, categories: Set(CopyCategory.allCases)).omittedPaths
    }

    static func claudeAbsoluteReferences(_ input: Data, sourcePath: String) throws -> [String] {
        let root = try JSONSerialization.jsonObject(with: input)
        var paths: [String] = []
        appendJSONReferences(root, path: "", sourcePath: sourcePath, to: &paths)
        return paths.sorted()
    }

    static func codexAbsoluteReferences(_ input: Data, sourcePath: String) throws -> [String] {
        let root = try TOMLTable(string: String(decoding: input, as: UTF8.self))
        var paths: [String] = []
        for key in root.keys {
            if let value = root[key] { appendTOMLReferences(value, path: key, sourcePath: sourcePath, to: &paths) }
        }
        return paths.sorted()
    }

    static func repairPluginJSON(_ input: Data, source: URL, destination: URL) throws -> Data {
        let root = try JSONSerialization.jsonObject(with: input)
        let repaired = repairJSONValue(root, source: source.standardizedFileURL.path,
                                       destination: destination.standardizedFileURL.path, key: nil)
        return try JSONSerialization.data(withJSONObject: repaired, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func normalized(_ key: String) -> String {
        var result = ""
        var previousWasLowercaseOrDigit = false
        for character in key {
            if character == "-" || character == " " {
                result.append("_")
                previousWasLowercaseOrDigit = false
            } else {
                if character.isUppercase, previousWasLowercaseOrDigit { result.append("_") }
                result.append(contentsOf: character.lowercased())
                previousWasLowercaseOrDigit = character.isLowercase || character.isNumber
            }
        }
        return result
    }

    private static func isReferenceKey(_ key: String) -> Bool {
        let key = normalized(key)
        return key == "env_key" || key == "bearer_token_env_var" || key.hasSuffix("_env_var")
    }

    private static func isCredentialKey(_ key: String) -> Bool {
        let key = normalized(key)
        if isReferenceKey(key) { return false }
        return key == "auth" || key == "authorization" || key == "proxy_authorization"
            || key == "cookie" || key == "set_cookie"
            || key == "credential" || key == "credentials" || key.hasSuffix("_credential") || key.hasSuffix("_credentials")
            || key == "password" || key == "passphrase" || key.hasSuffix("_password") || key.hasSuffix("_passphrase")
            || key == "token" || key.hasSuffix("_token") || key == "secret" || key.hasSuffix("_secret")
            || key == "apikey" || key == "api_key" || key.hasSuffix("_api_key")
            || key == "private_key" || key.hasSuffix("_private_key")
            || key == "secret_key" || key.hasSuffix("_secret_key")
            || key == "access_key" || key.hasSuffix("_access_key")
            || key == "access_key_id" || key.hasSuffix("_access_key_id")
    }

    private static func isCredentialEnvironmentVariable(_ key: String) -> Bool {
        let key = normalized(key)
        return isCredentialKey(key) || key.hasSuffix("_key")
    }

    private static func childContext(for key: String, current: ValueContext) -> ValueContext {
        if current == .identifierMap { return .ordinary }
        switch normalized(key) {
        case "mcp", "mcp_servers", "model_providers", "profiles", "projects", "plugins", "marketplaces",
             "enabled_plugins", "extra_known_marketplaces", "plugin_config", "hooks": return .identifierMap
        case "env": return .environment
        case "env_http_headers": return .environmentReferences
        case "http_headers", "headers": return .headers
        case "query_params": return .queryParameters
        default: return current == .environmentReferences ? .environmentReferences : .ordinary
        }
    }

    private static func shouldRemove(key: String, context: ValueContext) -> Bool {
        switch context {
        case .identifierMap: return false
        case .environment: return isCredentialEnvironmentVariable(key)
        case .environmentReferences: return false
        case .headers:
            let name = normalized(key)
            return isCredentialKey(key) || name == "key" || name == "authentication" || name.hasSuffix("_auth")
        case .queryParameters: return isCredentialKey(key) || normalized(key) == "key"
        case .ordinary: return isCredentialKey(key)
        }
    }

    private static func sanitizedJSON(
        _ value: Any, key: String, path: String, context: ValueContext, omittedPaths: inout [String]
    ) -> Any? {
        if shouldRemove(key: key, context: context) {
            appendJSONLeafPaths(value, path: path, to: &omittedPaths)
            return nil
        }
        let nextContext = childContext(for: key, current: context)
        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for (childKey, childValue) in dictionary {
                if let clean = sanitizedJSON(childValue, key: childKey, path: "\(path).\(childKey)",
                                             context: nextContext, omittedPaths: &omittedPaths) {
                    output[childKey] = clean
                }
            }
            return output
        }
        if let array = value as? [Any] {
            return array.enumerated().compactMap { index, item in
                sanitizedJSON(item, key: "item", path: "\(path)[\(index)]", context: nextContext,
                              omittedPaths: &omittedPaths)
            }
        }
        return value
    }

    private static func appendJSONLeafPaths(_ value: Any, path: String, to paths: inout [String]) {
        if let dictionary = value as? [String: Any], !dictionary.isEmpty {
            for (key, value) in dictionary { appendJSONLeafPaths(value, path: "\(path).\(key)", to: &paths) }
        } else if let array = value as? [Any], !array.isEmpty {
            for (index, value) in array.enumerated() { appendJSONLeafPaths(value, path: "\(path)[\(index)]", to: &paths) }
        } else { paths.append(path) }
    }

    private static func appendJSONReferences(_ value: Any, path: String, sourcePath: String, to paths: inout [String]) {
        if let dictionary = value as? [String: Any] {
            for (key, value) in dictionary {
                appendJSONReferences(value, path: path.isEmpty ? key : "\(path).\(key)", sourcePath: sourcePath, to: &paths)
            }
        } else if let array = value as? [Any] {
            for (index, value) in array.enumerated() {
                appendJSONReferences(value, path: "\(path)[\(index)]", sourcePath: sourcePath, to: &paths)
            }
        } else if let string = value as? String, string.contains(sourcePath) {
            paths.append(path)
        }
    }

    private static func sanitizedTOML(
        _ value: TOMLValueConvertible, key: String, path: String, context: ValueContext,
        categories: Set<CopyCategory>, omittedPaths: inout [String]
    ) -> TOMLValueConvertible? {
        let keyName = normalized(key)
        let excludedCategory = context == .ordinary && (
            (keyName == "mcp_servers" && !categories.contains(.connections))
            || ((keyName == "plugins" || keyName == "marketplaces") && !categories.contains(.plugins))
            || keyName == "hooks" || keyName == "notify")
        if excludedCategory {
            appendTOMLLeafPaths(value, path: path, to: &omittedPaths)
            return nil
        }
        if shouldRemove(key: key, context: context) {
            appendTOMLLeafPaths(value, path: path, to: &omittedPaths)
            return nil
        }
        let nextContext = childContext(for: key, current: context)
        if let table = value.table {
            let output = TOMLTable(inline: table.inline)
            for childKey in table.keys {
                if let child = table[childKey],
                   let clean = sanitizedTOML(child, key: childKey, path: "\(path).\(childKey)", context: nextContext,
                                             categories: categories, omittedPaths: &omittedPaths) {
                    output[childKey] = clean
                }
            }
            return output
        }
        if let array = value.array {
            let output = TOMLArray()
            for (index, item) in array.enumerated() {
                if let clean = sanitizedTOML(item, key: "item", path: "\(path)[\(index)]", context: nextContext,
                                             categories: categories, omittedPaths: &omittedPaths) {
                    output.append(clean)
                }
            }
            return output
        }
        return value.tomlValue
    }

    private static func appendTOMLLeafPaths(_ value: TOMLValueConvertible, path: String, to paths: inout [String]) {
        if let table = value.table, !table.keys.isEmpty {
            for key in table.keys {
                if let child = table[key] { appendTOMLLeafPaths(child, path: "\(path).\(key)", to: &paths) }
            }
        } else if let array = value.array, !array.isEmpty {
            for (index, child) in array.enumerated() { appendTOMLLeafPaths(child, path: "\(path)[\(index)]", to: &paths) }
        } else { paths.append(path) }
    }

    private static func appendTOMLReferences(
        _ value: TOMLValueConvertible, path: String, sourcePath: String, to paths: inout [String]
    ) {
        if let table = value.table {
            for key in table.keys {
                if let child = table[key] { appendTOMLReferences(child, path: "\(path).\(key)", sourcePath: sourcePath, to: &paths) }
            }
        } else if let array = value.array {
            for (index, child) in array.enumerated() {
                appendTOMLReferences(child, path: "\(path)[\(index)]", sourcePath: sourcePath, to: &paths)
            }
        } else if let string = value.string, string.contains(sourcePath) {
            paths.append(path)
        }
    }

    private static let pluginPathKeys: Set<String> = ["installLocation", "installPath", "sourcePath", "cachePath", "path"]

    private static func repairJSONValue(_ value: Any, source: String, destination: String, key: String?) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, element in
                result[element.key] = repairJSONValue(element.value, source: source, destination: destination, key: element.key)
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
