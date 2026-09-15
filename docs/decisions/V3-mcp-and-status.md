# V3 — MCP and lifecycle integration

Status: server and fixture adapters implemented; real-client gate open.

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

Codex 0.154.0 includes a shared local app-server daemon. Its generated `thread/start` schema accepts config overrides but does not establish per-thread process environment behavior. An isolated empty-profile startup was observed rendering the Codex sign-in screen; no provider task was submitted and no daemon was created before sign-in. This does **not** settle authenticated-session behavior.

Before claiming Codex integration works, verify two simultaneous tokens against one preset directory and scoped stop behavior. If the shared daemon reuses its environment, run a private foreground app-server per Chauffeur Codex session and connect the native TUI using `--remote unix:///...`; ownership and lifetime must include both processes. Do not stop the user's shared daemon as a session-stop mechanism.

Further required evidence: real clients list/call all tools, preserve existing MCP servers, deliver documented lifecycle events, and correctly resume recorded IDs. Codex approval/input signals remain degraded until a trusted launch-scoped route is proved. No automatic idle wake is claimed.

## Skill loading

Planned Claude route: bundle a namespaced plugin skill and load using `--plugin-dir`, verified in installed help. Planned Codex route: a namespaced directory under documented user `.agents/skills` discovery with explicit install/removal controls. Neither route is implemented or validated yet. Tool descriptions already explain the essential workflow without a skill.
