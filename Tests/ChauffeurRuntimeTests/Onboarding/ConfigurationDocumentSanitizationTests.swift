import ChauffeurCore
import Foundation
import Testing
@testable import ChauffeurRuntimeKit

struct ConfigurationDocumentSanitizationTests {
    @Test func nestedUnsupportedAndUnselectedFieldsAppearInPreviewOmissions() throws {
        let input = Data("""
        [profiles.work]
        notify = ["do-not-display"]
        [profiles.work.mcp_servers.local]
        command = "helper"
        [profiles.work.hooks]
        command = "another-private-command"
        """.utf8)
        let result = try ConfigurationDocument.sanitizedCodexTOML(input, categories: [.preferences])
        #expect(result.omittedPaths.contains("profiles.work.notify[0]"))
        #expect(result.omittedPaths.contains("profiles.work.hooks.command"))
        #expect(result.omittedPaths.contains("profiles.work.mcp_servers.local.command"))
        #expect(!result.omittedPaths.joined().contains("do-not-display"))
    }

    @Test func credentialHeadersAndQueryKeysAreRemovedWithoutDroppingIdentifiers() throws {
        let json = Data(#"{"mcpServers":{"secret_access_key":{"url":"https://example.invalid","headers":{"X-Aws-Secret-Access-Key":"header-secret","X-Auth":"auth-secret","Accept":"application/json"},"query_params":{"key":"query-secret","page":2}}}}"#.utf8)
        let result = try ConfigurationDocument.sanitizedClaudeJSON(json, categories: [.connections])
        let output = String(decoding: result.data, as: UTF8.self)
        #expect(output.contains("secret_access_key"))
        #expect(output.contains("application/json"))
        #expect(output.contains("page"))
        #expect(!output.contains("header-secret"))
        #expect(!output.contains("auth-secret"))
        #expect(!output.contains("query-secret"))
        #expect(result.omittedPaths.contains("mcpServers.secret_access_key.query_params.key"))
        let toml = Data("""
        [mcp_servers.secret_access_key]
        url = "https://example.invalid"
        [mcp_servers.secret_access_key.http_headers]
        X-Aws-Secret-Access-Key = "header-secret"
        Accept = "application/json"
        [mcp_servers.secret_access_key.query_params]
        key = "query-secret"
        page = "2"
        """.utf8)
        let codex = try ConfigurationDocument.sanitizedCodexTOML(toml, categories: [.connections])
        let codexOutput = String(decoding: codex.data, as: UTF8.self)
        #expect(codexOutput.contains("secret_access_key"))
        #expect(codexOutput.contains("application/json"))
        #expect(!codexOutput.contains("header-secret"))
        #expect(!codexOutput.contains("query-secret"))
        #expect(codex.omittedPaths.contains("mcp_servers.secret_access_key.http_headers.X-Aws-Secret-Access-Key"))
    }

    @Test func claudeMCPIdentifiersAndOrdinaryEnvironmentSurviveWhileCredentialValuesAreReported() throws {
        let input = Data(#"""
        {
          "mcpServers": {
            "github-auth": {
              "command": "github-helper",
              "env": {"PATH": "/usr/bin", "NODE_ENV": "test", "SERVICE_API_KEY": "fixture-key"},
              "headers": {"Authorization": "fixture-auth", "Cookie": "fixture-cookie", "X-Trace": "keep"}
            },
            "authoring-tools": {"command": "author"},
            "auth": {"command": "auth-server"},
            "tokens": {"command": "token-server", "accessToken": "fixture-token"},
            "plugins": {"command": "plugin-server", "token": "fixture-plugin-token"}
          }
        }
        """#.utf8)

        let result = try ConfigurationDocument.sanitizedClaudeJSON(input, categories: [.connections])
        let text = String(decoding: result.data, as: UTF8.self)
        #expect(text.contains("github-auth"))
        #expect(text.contains("authoring-tools"))
        #expect(text.contains("auth-server"))
        #expect(text.contains("token-server"))
        #expect(text.contains("plugin-server"))
        #expect(text.contains("NODE_ENV") && text.contains("PATH") && text.contains("X-Trace"))
        #expect(!text.contains("fixture-key") && !text.contains("fixture-auth"))
        #expect(!text.contains("fixture-cookie") && !text.contains("fixture-token"))
        #expect(result.omittedPaths == [
            "mcpServers.github-auth.env.SERVICE_API_KEY",
            "mcpServers.github-auth.headers.Authorization",
            "mcpServers.github-auth.headers.Cookie",
            "mcpServers.plugins.token",
            "mcpServers.tokens.accessToken"
        ])
    }

    @Test func codexReferencesAndPluginMarketplacesSurviveWithoutInlineCredentials() throws {
        let input = Data("""
        [mcp_servers.github-auth]
        command = "github-helper"
        env_key = "SERVICE_TOKEN"
        bearer_token_env_var = "BEARER_TOKEN"
        [mcp_servers.github-auth.env]
        PATH = "/usr/bin"
        NODE_ENV = "test"
        SERVICE_API_KEY = "fixture-key"
        [mcp_servers.github-auth.env_http_headers]
        Authorization = "AUTH_HEADER_ENV"
        X-Api-Key = "API_HEADER_ENV"
        [mcp_servers.github-auth.http_headers]
        Authorization = "fixture-auth"
        Cookie = "fixture-cookie"
        X-Trace = "keep"
        [mcp_servers.auth]
        command = "auth-server"
        [mcp_servers.env_http_headers]
        Authorization = "fixture-identifier-auth"
        [mcp_servers.plugins]
        token = "fixture-plugin-token"
        [marketplaces.personal]
        source = "/marketplace"
        [plugins."authoring-tools@personal"]
        enabled = true
        """.utf8)

        let connections = try ConfigurationDocument.sanitizedCodexTOML(input, categories: [.connections])
        let connectionText = String(decoding: connections.data, as: UTF8.self)
        #expect(connectionText.contains("github-auth") && connectionText.contains("auth-server"))
        #expect(connectionText.contains("env_key") && connectionText.contains("bearer_token_env_var"))
        #expect(connectionText.contains("env_http_headers") && connectionText.contains("AUTH_HEADER_ENV"))
        #expect(connectionText.contains("PATH") && connectionText.contains("NODE_ENV") && connectionText.contains("X-Trace"))
        #expect(!connectionText.contains("fixture-key") && !connectionText.contains("fixture-auth"))
        #expect(!connectionText.contains("fixture-cookie"))
        #expect(!connectionText.contains("fixture-identifier-auth"))
        #expect(!connectionText.contains("fixture-plugin-token"))
        #expect(connections.omittedPaths.contains("mcp_servers.github-auth.env.SERVICE_API_KEY"))
        #expect(connections.omittedPaths.contains("mcp_servers.github-auth.http_headers.Authorization"))
        #expect(connections.omittedPaths.contains("mcp_servers.github-auth.http_headers.Cookie"))

        let plugins = String(decoding: try ConfigurationDocument.codexTOML(input, categories: [.plugins]), as: UTF8.self)
        #expect(plugins.contains("marketplaces") && plugins.contains("authoring-tools@personal"))
        #expect(!plugins.contains("mcp_servers"))
    }

    @Test func claudeAccountFileImportsOnlySanitizedMCPConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-claude-account-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let staging = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let account = source.appendingPathComponent(".claude.json")
        try Data(#"{"account":{"email":"person@example.test","accessToken":"fixture-account-token"},"oauth":{"refreshToken":"fixture-refresh"},"mcpServers":{"github-auth":{"command":"helper","env":{"PATH":"/usr/bin","API_KEY":"fixture-mcp-key"}}}}"#.utf8).write(to: account)
        let pair = SetupAgentPair(kind: .claude, choice: .create, sourcePath: source.path,
                                  destinationPath: root.appendingPathComponent("destination").path,
                                  categories: [.connections])
        let adapter = ClaudeConfigurationMigration()
        let preview = try adapter.preview(pair: pair)
        #expect(preview.entries.contains { $0.destinationRelativePath == ".claude.json" })
        #expect(preview.warnings.contains { $0.contains("account.email") && $0.contains("account.accessToken") && $0.contains("oauth.refreshToken") })
        #expect(preview.warnings.allSatisfy { !$0.contains("fixture-") && !$0.contains("person@example.test") })

        // Changes to excluded account state do not alter the reviewed MCP-only destination document.
        try Data(#"{"account":{"email":"changed@example.test","accessToken":"changed-token"},"oauth":{"refreshToken":"changed-refresh"},"mcpServers":{"github-auth":{"command":"helper","env":{"PATH":"/usr/bin","API_KEY":"changed-mcp-key"}}}}"#.utf8).write(to: account)
        try adapter.write(preview: preview, pair: pair, staging: staging)
        let output = try String(contentsOf: staging.appendingPathComponent(".claude.json"), encoding: .utf8)
        #expect(output.contains("github-auth") && output.contains("PATH"))
        #expect(!output.contains("account") && !output.contains("oauth"))
        #expect(!output.contains("changed-") && !output.contains("API_KEY"))
    }

    @Test func previewsWarnAboutRetainedAbsoluteReferencesWithoutPrintingTheirValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-reference-warning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let referencedValue = source.appendingPathComponent("bin/status.sh").path
        try Data(#"{"statusLine":{"type":"command","command":"\#(referencedValue)"}}"#.utf8)
            .write(to: source.appendingPathComponent("settings.json"))
        let pair = SetupAgentPair(kind: .claude, choice: .create, sourcePath: source.path,
                                  destinationPath: root.appendingPathComponent("destination").path,
                                  categories: [.preferences])
        let preview = try ClaudeConfigurationMigration().preview(pair: pair)
        #expect(preview.warnings.contains { $0.contains("statusLine.command") && $0.contains("not copied automatically") })
        #expect(preview.warnings.allSatisfy { !$0.contains(referencedValue) })
    }

    @Test func defaultClaudeSourceImportsItsBoundedSiblingAccountMCPOnly() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chauffeur-default-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let source = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"account":{"accessToken":"fixture-account"},"mcpServers":{"docs":{"command":"docs"}}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        let pair = SetupAgentPair(kind: .claude, choice: .create, sourcePath: source.path,
                                  destinationPath: home.appendingPathComponent("destination").path,
                                  categories: [.connections])
        let preview = try ClaudeConfigurationMigration(homeDirectory: home).preview(pair: pair)
        #expect(preview.entries.contains { $0.destinationRelativePath == ".claude.json" })
        #expect(preview.warnings.contains { $0.contains("outside the selected source folder") })
        #expect(preview.warnings.allSatisfy { !$0.contains("fixture-account") })

        let unrelated = home.appendingPathComponent("other/.claude")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let unrelatedPair = SetupAgentPair(kind: .claude, choice: .create, sourcePath: unrelated.path,
                                           destinationPath: home.appendingPathComponent("other-destination").path,
                                           categories: [.connections])
        #expect(try ClaudeConfigurationMigration(homeDirectory: home).preview(pair: unrelatedPair).entries.isEmpty)
    }
}
