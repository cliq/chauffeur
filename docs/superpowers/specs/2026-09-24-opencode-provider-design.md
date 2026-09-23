# OpenCode as a first-party agent provider

Date: 2026-09-24
Branch: `feature/opencode`

## Goal

Add OpenCode (`opencode`, tested with 1.18.23) as a third first-party agent provider beside Claude Code and Codex, supporting the same
features: presets, launch options, status and attention, resume, Chauffeur MCP coordination, delegation, coordinator waking, the
coordination skill, follow-ups, onboarding and mobile. The motivating use is running agents on local models (e.g. an MLX server behind
an OpenAI-compatible provider in the user's OpenCode config), but nothing in Chauffeur is specific to local models.

Along the way, replace the scattered `switch` statements on `CLIKind` with a provider protocol, and add an "Auto-approve" launch option
for all providers.

## Decisions

- **Integration approach:** run OpenCode's own TUI in tmux, like Claude and Codex, and inject a Chauffeur plugin per launch for status,
  inbox and waking. Pivot option: a headless `opencode serve` per session with `opencode attach` in tmux, where Chauffeur uses HTTP/SSE
  for status, prompts and session IDs. The verification spike probes both approaches and picks one using the decision rule in section 5.
  Later in implementation, we pivot only if the plugin path cannot deliver reliable status, inbox continuation or follow-ups. ACP
  (`opencode acp`) is rejected because it drops the native TUI.
- **Local models:** Chauffeur does not manage model servers. Models and providers come from the user's OpenCode config. If a local server
  is down, OpenCode reports the error. A reachability check or managed model server can come later.
- **Configuration:** OpenCode uses the shared global config (`~/.config/opencode`) by default. A team preset may set another configuration
  directory, which is passed as `OPENCODE_CONFIG_DIR`. Chauffeur's per-launch additions always travel in `OPENCODE_CONFIG_CONTENT`, and
  nothing is written into the user's OpenCode config.

## Verified OpenCode facts (1.18.23)

- `OPENCODE_CONFIG_CONTENT` (inline JSON config) and `OPENCODE_CONFIG_DIR` are supported.
- The `plugin` config array accepts `file:///abs/path/plugin.js`.
- `~/.claude/skills/*/SKILL.md` and `~/.agents/skills/*/SKILL.md` are auto-loaded.
- Config values support `{env:VAR}` substitution.
- The TUI accepts `-m/--model provider/model`, `--agent`, `--auto`, `-s/--session <id>`, `-c/--continue`, `--fork` and `--prompt`.
- `--version` prints a bare semver (`1.18.23`).
- Plugins receive bus events including `session.created`, `session.status`, `session.idle`, `session.error`, `permission.asked/replied`,
  `question.asked/replied`, and they get an SDK client for the running session. An existing third-party status plugin (Orca's) relies on
  these events.

Everything else below that depends on OpenCode behaviour is listed under "Verification spike".

## 1. Provider protocol refactor

`CLIKind` stays the persisted identifier: the raw value in presets, `configurationDirectories`, `executables`, `accountCounts`, the
remote protocol and `chauffeurctl --provider`. Per-provider behaviour moves behind two protocols that follow the existing module
boundaries.

### `AgentProvider` (ChauffeurCore, pure, no I/O)

- Identity: `kind`, `displayName`, `identifies(version:help:)`.
- Configuration: `defaultConfigurationDirectory`, and `environment(configurationDirectory:)` returning the profile selector
  (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, or `OPENCODE_CONFIG_DIR` when not the default).
- Argument grammar used by `LaunchPolicy.validateArguments`: blocked (Chauffeur-managed) keys, options that take values, flags, and
  short-option conflict prefixes.
- Launch options used by `LaunchOptions`: how model, reasoning and auto-approve are recognized and rewritten, curated suggestions, and
  the enforced auto-approve flag.
- `composerReadiness(activeLine:)` for follow-ups.
- Capability flags that replace `kind == .claude` / `kind == .codex` checks in `RuntimeCoordinator` and elsewhere, e.g.
  `preassignsConversationID`, `supportsReasoning`, `validatesConversationID(_:)`, the coordinator wake strategy.
- Presentation: badge colour, install URL, and the caption for the auto-approve option.

### `ProviderIntegration` (ChauffeurRuntimeKit, performs I/O)

- `capabilities(executable:environment:)`: probes `--version` / `--help` (and, for OpenCode, `opencode models`).
- `launchArguments(session:endpoint:ctlPath:integrationDirectory:coordination:resume:)`: builds arguments and writes any per-launch
  files (Claude's `mcp.json` and `settings.json`) or environment additions (OpenCode's `OPENCODE_CONFIG_CONTENT`).
- Optional launch preparation (Codex hook trust), so `RuntimeCoordinator` no longer branches on Codex.

`CLIKind.provider` returns the conformer, or `nil` for `.shell`. Shell sessions keep their own small code path.

Onboarding authentication and configuration migration already use per-provider adapter maps (`OnboardingCoordinator`,
`ConfigurationPublisher`). They only gain OpenCode entries.

### Order

1. Characterization tests that pin current Claude and Codex behaviour.
2. Move Claude and Codex behind the protocols with no behaviour change, as its own commit.
3. Add OpenCode as a third conformer.

## 2. Launch and presets

### Base preset

- A third seeded base preset, "OpenCode" (executable `opencode`, kind `.opencode`), with its configuration directory defaulting to
  `~/.config/opencode`.
- Existing installs get it added the same way as the Claude and Codex presets. If it isn't installed, it shows as missing.

### Identification and capabilities

- `identifies`: `--version` output must be semver-shaped, and `--help` must list OpenCode's own subcommands (`opencode serve`,
  `opencode acp`). No version is pinned.
- `resume`: `--help` lists `-s/--session`.
- `delegatedYOLO`: `--help` lists `--auto`.
- `additionalDirectories`: granted through config (`permission.external_directory` with `"<path>/**": "allow"` per path), since OpenCode
  has no `--add-dir`. If the spike shows this doesn't work, the capability reports false.
- Model suggestions: `opencode models` output, fetched during the capability probe and cached per executable and config directory.
  Free text stays allowed.

### Arguments

- New session: `opencode [user args] [--prompt <task>]`, with the working directory as cwd.
- Resume: `opencode [user args] -s <id>`. OpenCode IDs are `ses_…`, so the resume check accepts that shape instead of requiring a UUID.
- Delegated workers get `--auto` enforced.
- `supportsReasoning` is false: OpenCode has no reasoning-effort flag. Agent-style variants are selected with `--agent`.

### Argument policy

- Allowed user arguments: `-m/--model`, `--agent`, `--auto`, `--log-level`, `--print-logs`.
- Blocked as Chauffeur-managed: `-c/--continue`, `-s/--session`, `--fork`, `--prompt`, `--port`, `--hostname`, `--mdns`,
  `--mdns-domain`, `--cors`, the project positional, and subcommands.
- Also blocked: `--pure`, which disables plugins and would silently kill status tracking, and `--mini`, a different UI that breaks
  composer detection.

### Environment

- Add `OPENCODE_` to `LaunchPolicy.deniedPrefixes`, so inherited OpenCode state (e.g. a parent session's `OPENCODE_CONFIG_CONTENT`)
  never leaks in.
- Set `OPENCODE_CONFIG_DIR` only when the preset's configuration directory differs from `~/.config/opencode`.
- The existing stripping of `OPENAI_`, `ANTHROPIC_` and similar prefixes stays. A config that reads `{env:OPENAI_API_KEY}` loses that
  key under Chauffeur. This is documented in `docs/compatibility.md`, and the behaviour does not change.

### Auto-approve launch option (all providers)

- A third `LaunchOptionField`, `.autoApprove` (boolean), shown as an **Auto-approve** checkbox next to the model and reasoning pickers in
  `ArgumentEditor`: both in the preset editor and in the launch sheet's per-session overrides.
- Each provider supplies the caption and flag:
  - Claude: "Skips permission prompts" (`--dangerously-skip-permissions`)
  - Codex: "Skips approvals and the sandbox" (`--dangerously-bypass-approvals-and-sandbox`)
  - OpenCode: "Approves anything not explicitly denied" (`--auto`)
- Checking the box adds the canonical flag. Unchecking removes every recognized form: Codex `--yolo`, and Claude
  `--permission-mode bypassPermissions`, where only that option is removed.
- Editing the arguments text box updates the checkbox, the same way it updates model and reasoning.
- On the launch sheet, the override starts at the preset's value.
- Delegated workers still have the flag enforced by `LaunchOptions.resolve(delegated:)`, whatever the checkbox says.

## 3. Status plugin, MCP and coordination

### Plugin delivery

- A bundled `chauffeur-opencode.js` is published to Application Support next to the managed skills.
- Each launch references it through `OPENCODE_CONFIG_CONTENT` → `plugin: ["file:///…/chauffeur-opencode.js"]`.
- The plugin does nothing unless `CHAUFFEUR_SESSION_ID` and `CHAUFFEUR_CTL` are set.

### Status mapping

- Every event goes through `chauffeurctl` with a hook payload whose `session_id` is the OpenCode `ses_…` ID, so `HookPayload.parse` and
  `RuntimeCoordinator.applyEvent` keep their current contract.
- Events from child sessions (`parentID` set) are ignored. OpenCode's task tool spawns subagent sessions, which must not change the
  parent's status or claim its conversation ID.
- Status is reported only on transitions, to avoid spawning `chauffeurctl` per streamed part.

| OpenCode event | Chauffeur |
|---|---|
| `session.created` (root) | `session-start`, adopts the conversation ID |
| `session.status` busy, tool events | `running` |
| `permission.asked`, `question.asked` | `needs-attention` |
| `permission.replied`, `question.replied` | `running` |
| `session.error` | `needs-attention` |
| `session.idle` | `inbox-hook --provider opencode --report-stop` (below) |

### Turn end and inbox (matches Claude's Stop hook)

- On `session.idle`, the plugin runs the inbox hook.
- If the hook asks to keep the turn going for new mail, the plugin calls `client.session.promptAsync` with the hint text instead of
  reporting turn end.
- Otherwise the hook reports `turn-finished`.
- Mid-turn mail reminders, which Claude gets on UserPromptSubmit and PostToolUse, are appended to tool results in `tool.execute.after`.
- `chauffeurctl inbox-hook` gains an `opencode` provider that uses the same formatter (`InboxHintFormatter`) and the same output
  contract the plugin parses.

### Coordinator waiting (matches Claude's background waiter)

- OpenCode's bash tool cannot run a process in the background, so the plugin takes over that job.
- When a coordinator goes idle with open workers, the plugin spawns `chauffeurctl wait-for-work` itself.
- When that returns a milestone, the plugin sends the wake prompt through `promptAsync`.
- When the session turns busy because the user typed, the plugin kills the waiter.
- The runtime's current wake rules apply unchanged: wake only on worker milestones, ignore workers the coordinator closed.
- Fallback if the spike rules this out: Codex's tmux-typed wake (`wakeIdleCoordinators`), selected through the provider's wake
  strategy.

### MCP

- `OPENCODE_CONFIG_CONTENT` → `mcp.chauffeur = {type: "remote", url: <endpoint>, headers: {Authorization: "Bearer {env:CHAUFFEUR_SESSION_TOKEN}"}}`.
- Also `permission` allowing `chauffeur_*` tools, so interactive sessions aren't prompted for Chauffeur's own tools.
- Chauffeur's blocking tools need calls of up to about 360 s. The spike confirms which OpenCode setting controls the MCP tool-call
  timeout, and the config sets it.

### Skill

- `SkillInstaller` publishes the managed skills into `~/.agents/skills` whenever any Codex or OpenCode preset is in use (today it does
  this for Codex only). OpenCode auto-loads that directory.

### Follow-ups

- The existing `TmuxHost.submitFollowUp` bracketed-paste path.
- An OpenCode `composerReadiness` rule, derived from capturing the TUI's empty prompt line.
- If screen detection proves unreliable, this is the first candidate for the pivot to approach 2.

## 4. Onboarding, UI and mobile

### Core types

- `CLIKind.opencode` (raw value `"opencode"`) and `RemoteSessionKind.opencode`.
- `RemoteSessionKind` decodes unknown values as a generic agent, so a mobile build older than the Mac doesn't fail to decode inventories
  that include newer providers.

### Onboarding

- `AgentSetupStep` lists OpenCode automatically, with an install link to opencode.ai. It is optional in `AgentSelection`, like the other
  agents.
- `ConfigurationDiscovery` detects `~/.config/opencode` and the executable on `PATH`.
- Authentication adapter:
  - Ready when `opencode models` lists at least one model.
  - Otherwise "No models configured", pointing to OpenCode's provider docs.
  - An optional action runs `opencode auth login` for cloud-provider users.
- Configuration migration adapter:
  - No-op for the shared default directory.
  - For an override directory, it offers to copy `opencode.json(c)`, `agents/` and `plugins/` from `~/.config/opencode`.

### App UI

- `AgentProvider` supplies `displayName` "OpenCode", a neutral teal badge colour (distinct from Claude orange and Codex blue), and the
  install URL.
- Settings pickers, `ProjectTeamControl` and `BaseAgentPresetsView` read the provider list instead of hardcoding two providers.

### Mobile

- `Inventory+Lookups` and `SessionsView` get the OpenCode label and colour, through a small local mapping, since mobile doesn't link
  ChauffeurCore.

### Docs

- `docs/compatibility.md`: an OpenCode row, its limitations, and the environment-stripping note.
- A new `docs/decisions/` record: the plugin approach, the rejected options, and the conditions for pivoting to approach 2.

## 5. Testing and verification

### Verification spike

Throwaway work, done first. It checks against OpenCode 1.18.23 and the local MLX setup:

1. `OPENCODE_CONFIG_CONTENT` merges its `plugin` array with the user's existing plugins, and does not replace the user's `mcp` or
   `provider` maps.
2. A `file://` plugin loads, and its bus events arrive as expected, including `parentID` on child sessions.
3. What `OPENCODE_CONFIG_DIR` does: add a layer, or replace the global directory.
4. `permission.external_directory` grants work for additional paths.
5. An MCP tool call can block for about 360 s, and which setting controls that.
6. `tool.execute.after` can append to a tool's output.
7. `client.session.promptAsync` called from a `session.idle` handler starts a new turn that is visible in the TUI.
8. A plugin can spawn and kill a long-running child process (`wait-for-work`) without blocking OpenCode.
9. The exact empty-composer line, and the line shown with a draft or an open dialog.

10. Approach 2 probe: `opencode serve` plus `opencode attach <url>` in tmux, on the same machine and config:
    - whether the attached TUI is equivalent for the user: rendering, input, permission and question dialogs, and resizing
    - whether the server's event stream carries the same session events, with root and child sessions distinguishable
    - whether a prompt can be submitted over HTTP while the TUI is attached, and shows in the TUI as if typed
    - whether sessions can be created with an initial prompt and resumed by ID
    - per-session cost: startup time, memory, choosing a port, and whether the server exits when the tmux session ends

### Decision rule

- If 1, 2 or 7 fails in a way that can't be worked around, use approach 2, as long as the probe in 10 passes.
- If both approaches pass, prefer approach 2 when it removes a workaround approach 1 depends on, such as an unreliable composer rule
  for follow-ups or flaky `promptAsync` continuation, and its lifecycle costs are acceptable. Otherwise keep approach 1, which reuses
  the existing session model.
- If approach 2 is chosen, sections 2–4 are revised before the implementation plan is written. The provider refactor, presets,
  Auto-approve, onboarding and mobile parts carry over unchanged.

### Automated tests

- **Characterization tests** before the refactor:
  - Claude and Codex `arguments(...)`, including the contents of files written.
  - `LaunchPolicy.validateArguments` and `LaunchPolicy.environment`.
  - `TmuxHost.composerReadiness`.
  - `LaunchOptions` inspect/update/resolve.
- **OpenCode unit tests:** identification, arguments and resume, argument validation, the generated `OPENCODE_CONFIG_CONTENT` JSON,
  environment, and composer readiness.
- **Auto-approve tests:** inspect and update for all three providers, including alternate forms and the interaction with delegated
  enforcement.
- **Plugin tests:** `node --test` against a fake SDK client and a fake `chauffeurctl`, covering:
  - the event mapping and transition-only reporting
  - ignoring child sessions
  - inbox continuation versus turn end
  - the waiter lifecycle
  - doing nothing without the Chauffeur environment

  They are wired into the `Makefile`.

### End-to-end checks

Scripted where possible, otherwise done by hand:

- An OpenCode coordinator on the local model delegates to an OpenCode worker and a Claude worker.
- Status, attention (permission and question prompts), waking, follow-ups and resume all behave.
- The session appears with the right label on mobile.

## Out of scope

- Managing or health-checking local model servers.
- Chauffeur-side model/provider configuration UI beyond the `opencode models` suggestions.
- Building approach 2 (`opencode serve` + `attach`), unless the spike's decision rule selects it.
