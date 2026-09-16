# V3 — MCP and lifecycle integration

Status: real Codex and Claude messaging, permissions, completion, resume and restart checks
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

## Real Codex evidence

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

## Real Claude evidence

`Prototypes/real_claude_integration.py` exercises Claude Code 2.1.272 through the
actual runtime, native interactive CLI and HTTP MCP client. The two authorized
clones retain their model settings and credentials; copied executable hooks,
plugins, status commands and local MCP registrations were disabled in the test
copies. The fixture uses native manual permission mode and disables built-in
tools for its bounded MCP-only tasks.

- Three sessions use two configuration directories. Native account screens and
  live process indicators match the selected clones. Invalid inherited provider
  credentials are absent. Both clones currently report the same account and
  organization; see [V2](V2-configuration-selection.md) for the evidence limit.
- Six `chauffeur_send_message` operations have the expected authenticated sender
  and recipient. The probe verifies the displayed arguments and one-time Yes
  selection before approving. It installs no persistent approval rule.
- Permission prompts reach `Needs attention` through Chauffeur's lifecycle
  hooks before approval. Completion hooks record `Turn finished` for each of
  the three initial tasks, with the expected native conversation IDs.
- Stopping one execution leaves its peer on the same profile usable. Explicit
  resume keeps the native conversation ID, starts a new process and uses the
  reissued Chauffeur credential successfully.
- Runtime termination/restart preserves all three CLI processes and the MCP
  endpoint. A surviving Claude client makes another successful message call.

Claude's native status also listed other MCP connections, which the fixture did
not invoke. The controlled existing-server preservation case remains open.
The `--startup-only` option checks account displays and process configuration
without an inference prompt. Reports omit account identifiers and credential
values; terminal/history artifacts under `.local/real-claude-artifacts/` are
private and may contain native account displays.

## Focused native status evidence — 2026-09-16

`Prototypes/native_attention_smoke.py` passes with Codex 0.154.0 and Claude Code
2.1.273 in separate isolated signed Debug app runs. Each uses one authorized
profile clone and a temporary project. Native keyboard input requests exactly
one read-only `chauffeur_discover` call; the probe checks its displayed name and
one-time approval selection before approving it. The authenticated runtime log
confirms that call and no other tool use.

Claude's permission request appears as **Needs attention** in the app, tool
completion clears attention, and the final reply records **Turn finished** with
its native conversation ID. Codex also records completion and its conversation
ID; its approval prompt remains **Activity unknown**, the documented limitation.
Native `/exit` yields **Exited** and exit status zero for both CLIs. Detailed
private evidence is under `.local/attention-native-{codex,claude}/`.

The initial Claude run reproduced a false attention state after a completed turn
sat idle. Its catch-all notification hook is now restricted to permission and
elicitation requests; a matching regression test rejects idle/authentication/
completion notifications. Post-tool hooks clear permission attention. The native
Claude check stays finished for 70 seconds with no input. Hook meanings follow
the [Claude hooks reference](https://code.claude.com/docs/en/hooks). API-error
`StopFailure` handling is configured but has not been induced in a real session.

These are focused status and discovery checks. They add Claude 2.1.273 to the
candidate integration baseline; they do not complete messaging/delegation or
change its unverified label. Those remaining coordination checks are in V2.

## Remaining gate evidence

Further evidence remains required for all tools, controlled pre-existing MCP
server preservation, inbox acknowledgement, and cross-provider delegation.
Codex approval/input status signals remain degraded until a trusted launch-scoped
route is proved. Native approval interaction is verified, but no automatic idle
wake is claimed. The integration remains labelled unverified until the full gate
passes. Private detailed Codex artifacts are under `.local/real-codex-artifacts/`;
only the redacted summaries are suitable for sharing.

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
