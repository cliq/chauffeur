import Testing
@testable import ChauffeurCore

@Suite struct SetupEnvironmentTests {
    @Test func inheritedAuthenticationCannotSelectAnotherProfile() {
        let env = SetupEnvironment.make(
            base: [
                "PATH": "/bin", "HOME": "/tmp/home", "ANTHROPIC_API_KEY": "fixture",
                "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/other", "CLAUDE_CONFIG_DIR": "/wrong",
                "CHAUFFEUR_SESSION_TOKEN": "secret", "HTTPS_PROXY": "https://proxy.example"
            ],
            kind: .claude,
            directory: "/profiles/work"
        )
        #expect(env["CLAUDE_CONFIG_DIR"] == "/profiles/work")
        #expect(env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(env["CHAUFFEUR_SESSION_TOKEN"] == nil)
        #expect(env["HTTPS_PROXY"] == "https://proxy.example")
        #expect(env["HOME"] == "/tmp/home")
    }

    @Test func codexGetsOnlyExplicitProfileAndNoSessionGrant() {
        let env = SetupEnvironment.make(
            base: ["PATH": "/bin", "CODEX_HOME": "/wrong", "OPENAI_API_KEY": "fixture", "SSL_CERT_FILE": "/certs/ca.pem"],
            kind: .codex,
            directory: "/profiles/personal"
        )
        #expect(env["CODEX_HOME"] == "/profiles/personal")
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(env["CHAUFFEUR_SESSION_ID"] == nil)
        #expect(env["CHAUFFEUR_SESSION_TOKEN"] == nil)
        #expect(env["SSL_CERT_FILE"] == "/certs/ca.pem")
    }
}
