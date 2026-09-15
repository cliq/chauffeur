# V3 — MCP and lifecycle integration

Status: real Codex messaging, permissions, completion, resume and restart checks
passed; full real-client/cross-provider gate remains open.

## Decision and implementation candidate

Hummingbird 2.26.0 hosts one loopback HTTP endpoint. The initial transport is stateless JSON Streamable HTTP with `initialize`, `ping`, `tools/list` and `tools/call`. No SSE, resources, or subscriptions are advertised. Each POST authenticates a session grant before routing. The selected port is saved so surviving clients can reconnect after a runtime restart.

Codex launch overrides configure the namespaced MCP URL, `bearer_token_env_var`, and `notify`. Claude gets per-launch MCP and settings files with environment expansion for the bearer token, and explicit native conversation IDs. Files in the native configuration directory are not rewritten. Claude's strict-MCP mode is never enabled. Hook events carry session credentials and cannot update another session.

The current baseline-version detector enables a candidate integration path and records it as **unverified**. It is not a support-matrix claim. Unknown CLI versions can explicitly launch in basic terminal mode, with coordination/status disabled. Additional-directory support is checked from help.

## Sources checked

- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference): namespaced HTTP MCP options and notify command.
- [Codex developer commands](https://learn.chatgpt.com/docs/developer-commands): explicit remote app-server connection and native resume.
- [Claude hooks](https://code.claude.com/docs/en/hooks) and [MCP configuration](https://code.claude.com/docs/en/mcp).
- [MCP Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

## Critical next validation

`Prototypes/real_codex_integration.py` exercises the actual runtime and Codex
0.154.0 with two authorized private profile clones and three real sessions. The
clones retain native model settings; unrelated copied hooks/plugins/MCP servers
were disabled for the fixture. Two sessions share a configuration directory.

- Six actual `chauffeur_send_message` calls have the expected authenticated
  senders/recipients. Native approval prompts show the exact arguments and receive
  one-time approval; no persistent approval rule is installed.
- `notify` records completion and each native conversation ID.
- Stopping one session leaves another session using that same profile usable.
- Explicit resume keeps the native conversation ID, starts a new process and
  successfully uses its reissued Chauffeur grant.
- Restarting the runtime preserves the live tmux processes and endpoint; a real
  client makes a new successful MCP call afterward.
- A `never` approval-policy fixture was rejected by native Codex before any
  message write. Chauffeur did not override that permission setting.

The real CLI first exposed an invalid launch configuration: JSON-escaped path
slashes are not valid TOML escapes. The adapter now emits TOML-compatible string
and array literals; the runtime fixture checks them with Python's TOML parser.

For the tested default launch route, per-session credentials and scoped stop are
now demonstrated. A separate foreground app-server is not required by this
evidence. This does not cover arbitrary native feature/configuration changes or
explicit remote/shared-daemon workflows; `--remote` remains a conflicting managed
argument. No user daemon is stopped by Chauffeur's session-stop implementation.

Further evidence remains required for all tools, preserved pre-existing MCP
servers, Claude hooks/resume, inbox acknowledgement, and cross-provider delegation.
Codex approval/input status signals remain degraded until a trusted launch-scoped
route is proved. Native approval interaction is verified, but no automatic idle
wake is claimed. The integration remains labelled unverified until the full gate
passes. Private detailed artifacts are under `.local/real-codex-artifacts/`;
only the redacted summary is suitable for sharing.

## Skill loading

The optional versioned skill is bundled and explicitly installed into the
selected profile's `skills/chauffeur` directory. Native Codex 0.154.0 and Claude
Code 2.1.272 metadata checks prove discovery in profile A, absence in profile B,
and removal. Codex was also checked with the authorized profile clones. The
Claude check uses normal discovery; its `--bare` metadata catalog was empty
and does not establish normal loading behavior.

Settings provides review/install/update/remove controls. Receipts and content
hashes prevent replacing or deleting edited or unmanaged files. Status checks
are read-only; stale reviews reject mutations after path or version changes.
The guidance is generic, shared by sessions using that profile, and optional.
Discovery now exposes the authenticated caller's parent/delegation IDs so a
child can report its result. Full model-driven acceptance remains open.
See [the skill guide](../coordination-skill.md) for loading sources, limitations,
recovery and the reproducible native/IPC fixture.
