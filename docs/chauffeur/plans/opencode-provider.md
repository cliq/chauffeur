# OpenCode provider: implementation plan

Spec: `docs/superpowers/specs/2026-09-24-opencode-provider-design.md`. Branch `feature/opencode`.
Installed OpenCode is 1.18.32 (the spec was written against 1.18.23). The local test model is `mlx_lm.server` serving
`~/models/Qwen3-14B-4bit` on `http://127.0.0.1:8081/v1`, wired through a spike-only `OPENCODE_CONFIG_CONTENT` provider, so the
user's `~/.config/opencode` is never edited.

## Stages

Stage 1 and stage 2 run in parallel, since the refactor carries over whichever approach the spike picks. Stages 3–7 run in order,
with the plugin JS (stage 5a) developed alongside the Swift work in stage 4.

### 1. Verification spike (throwaway, scratchpad only)

Answers spec §5 items 1–10 against 1.18.32 and the local model. Output: `docs/decisions/V9-opencode-integration.md` with findings,
the chosen approach under the decision rule, and the concrete values later stages need:

- the merge semantics of `OPENCODE_CONFIG_CONTENT` (`plugin`, `mcp`, `provider`) and of `OPENCODE_CONFIG_DIR`
- the plugin event names and payload shapes (root and child session IDs, `parentID`, status, permission and question events)
- whether `permission.external_directory` grants work
- the MCP timeout setting name, and whether a 360 s call survives
- whether `tool.execute.after` can mutate output, and whether `promptAsync` from `session.idle` starts a visible turn
- whether a plugin can spawn and kill a long-lived child process
- the empty-composer, draft and dialog lines captured from tmux
- the approach 2 probe (`serve` + `attach`)

### 2. Provider protocol refactor (no behaviour change)

1. Characterization tests: `CLIAdapter.arguments` for Claude and Codex, including the files written; `LaunchPolicy.validateArguments`
   and `.environment`; `TmuxHost.composerReadiness`; `LaunchOptions` inspect, update and resolve. Commit them.
2. `AgentProvider` in ChauffeurCore (`ClaudeProvider`, `CodexProvider`): identity, identification, configuration directory and
   environment key, argument grammar, launch-option recognition and rewriting, suggestions, YOLO enforcement, composer readiness,
   capability flags (`preassignsConversationID`, `supportsReasoning`, `validatesConversationID`, wake strategy, `defaultHomeFolder`),
   presentation (badge colour name, install URL). Add `CLIKind.provider`, which is nil for `.shell`.
3. `ProviderIntegration` in ChauffeurRuntimeKit: `capabilities`, `launchArguments` (returning arguments plus environment
   additions), and optional launch preparation (Codex hook trust). `CLIAdapter` becomes a thin façade, and `RuntimeCoordinator`,
   `LaunchPolicy`, `LaunchOptions`, `TmuxHost`, `NativeHooks`, `TeamAgents`, `ShellAgentEnvironment` and `SkillInstaller` read the
   provider instead of switching on the kind.
4. `swift test` stays green with the characterization tests unchanged. Commit.

### 3. Auto-approve launch option

`LaunchOptionField.autoApprove`, with inspect, update and resolve through each provider's flag and its alternate forms. Add the
`ArgumentEditor` checkbox in the preset editor and the launch sheet overrides. Tests for all providers and for delegated
enforcement. Commit.

### 4. OpenCode core

- `CLIKind.opencode`, `OpenCodeProvider` and `OpenCodeIntegration`
- identification, capabilities (help probes, plus `opencode models` suggestions cached per executable and config directory)
- new-session and resume arguments, the `ses_…` ID check, the argument policy, `OPENCODE_` in the denied prefixes, and
  `OPENCODE_CONFIG_DIR` only for a non-default directory
- `OPENCODE_CONFIG_CONTENT`: plugin, MCP with its timeout, the `chauffeur_*` permission and `external_directory` grants
- the seeded base preset, and the addition for existing installs
- how the runtime passes provider environment additions into tmux
- unit tests. Commit.

### 5. Plugin and coordination

a. `Resources/…/chauffeur-opencode.js`: event mapping, transition-only reporting, child-session filtering, inbox continuation
   through `promptAsync`, mid-turn reminders in `tool.execute.after`, and the coordinator waiter lifecycle. It is a no-op without the
   Chauffeur environment. `node --test` tests use a fake client and a fake ctl, wired into the `Makefile`.
b. `chauffeurctl inbox-hook --provider opencode`, with the output contract the plugin parses. Runtime changes: publish the plugin
   to Application Support, the OpenCode wake strategy, conversation ID adoption from `session-start`, and follow-up composer
   readiness.
c. `SkillInstaller` publishes to `~/.agents/skills` when a Codex or OpenCode preset is in use. Commit.

### 6. Onboarding, UI and mobile

- `ConfigurationDiscovery`, an authentication adapter (`opencode models`, with an `opencode auth login` action) and a configuration
  migration adapter
- `AgentSetupStep`, Settings, `ProjectTeamControl` and `BaseAgentPresetsView` read the provider list
- `RemoteSessionKind.opencode`, with unknown kinds decoded as a generic agent
- mobile label and colour. Tests. Commit.

### 7. Docs and end to end

- `docs/compatibility.md`, with the V9 decision record finalised
- a debug build, then end-to-end runs on the local model: an OpenCode coordinator delegating to an OpenCode worker and a Claude
  worker; status, attention, wake, follow-ups and resume; the mobile label (UI tests on the Maestro simulator if needed)
- a final review pass. Commit.
