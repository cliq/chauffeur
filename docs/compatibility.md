# CLI and platform compatibility

Last inspected: 2026-09-23. These are observed development-machine versions,
not a completed real-provider support matrix.

| Component | Version | Current evidence |
| --- | --- | --- |
| macOS | 26.6.2 (25G83), M5 Pro / 48 GB | Native app/runtime build; fixture integrations run |
| Swift | 6.2.4 | Swift 6 package builds; concurrency checking enabled |
| Xcode | 26.3 (17C529) | Native app builds and is signed locally |
| tmux | 3.6a | Alternate-screen redraw, resize, input, detachment/restart, native mouse/link forwarding, and sustained bounded capture pass; attachments advertise OSC 8 hyperlinks |
| SwiftTerm | 1.20.0 | Pinned; native terminal views implemented and exercised by the Debug probe |
| Hummingbird | 2.26.0 | Actual loopback MCP requests exercised with fixture credentials |
| Codex | 0.154.0 | Three real sessions/two profiles; authenticated messages, native approvals/completion, scoped stop, explicit resume and runtime reconnect pass. Native UI input/clipboard/resize/history and normal/forced UI quit preserve the process and draft |
| Codex | 0.155.1 | Authenticated cross-provider MCP delegation, messages/results, model/effort overrides, same-session follow-up, retry and retained closure pass; see [orchestration validation](orchestration-validation.md) |
| Codex | 0.156.1 | Inbox-reminder hooks in the interactive TUI: whole-map selective hook trust, `UserPromptSubmit`/`PostToolUse` context and one `Stop` continuation, MCP `PostToolUse`, and `/new`, `/clear`, `/resume`, `/fork` identity tracking, with a mock provider; see [inbox reminders](#inbox-reminders) |
| Claude Code | 2.1.280 | Inbox-reminder hooks, one `Stop` continuation, and `/clear`/`/resume` identity tracking in the interactive TUI with a mock provider; cross-provider mail with Codex 0.156.1 |
| Claude Code | 2.1.278 | Same orchestration checks pass in both coordinator and worker roles |
| Claude Code | 2.1.272 | Three real sessions/two profiles; native account/process configuration, authenticated messages, permission/completion hooks, scoped stop, explicit resume and runtime reconnect pass; both profiles report the same account |
| Claude Code | 2.1.273 | Basic-terminal launch/resume and checkout recovery pass; native UI input/clipboard/resize/history and normal/forced UI quit preserve the process and draft. Native permission/completion hooks, read-only MCP discovery and normal exit pass; full coordination remains unverified |
| OpenCode | 1.18.32 | Plugin status, MCP, inbox continuation, coordinator waiting and composer detection verified in the [V9 spike](decisions/V9-opencode-integration.md) with a local MLX model; end-to-end evidence below under [OpenCode](#opencode) |

`Prototypes/native_profile_selection.py` verifies two concurrent native project
windows per current CLI in the signed Release app. Native `/status` account
displays match the authorized clones, and actual child process indicators prove
the selected configuration directories and removal of inherited fake provider
credentials. Both live basic-mode sessions report **Activity unknown**. The
Codex clones have distinct stored account contexts; Claude A/B share an account,
and the different-account Claude check remains deferred by the user. No model
prompts are sent by this check.

## Capability behavior

### Team setup authentication

The onboarding adapters were checked against Codex 0.155.0 and Claude Code
2.1.278 help and unauthenticated status commands in fresh, isolated temporary
profiles. Codex reports `Not logged in` on stderr; Claude returns JSON status.
Parser fixtures also cover successful status, unknown output, and errors.
Login PTY lifecycle, environment isolation, and verification use fake CLIs in
automated tests. Real browser OAuth completion with separate provider accounts
has not been exercised for this wizard.

Setup uses `codex login` / `codex login status` and
`claude auth login` / `claude auth status --json`. Unsupported status output is
reported as Unable to verify, never inferred from credential-file presence.
This authentication check is independent of the coordination capability matrix
below and does not send a model prompt.

### Agent sessions

The adapter checks `--version` and `--help` before spawning an agent. Codex and
Claude Code are recognized by provider identity, without a version allowlist.
New releases remain coordination candidates; the table records tested versions,
not permitted versions. Missing `--add-dir` support rejects a multi-directory launch.
Missing native conversation IDs disable resume; no global resume selector is used.

Codex 0.154.0 rejects `--add-dir` with a read-only sandbox. Chauffeur reports an
explicit `-s read-only` or `--sandbox read-only` agent preset combined with additional
folders before inspecting or spawning the CLI (including `=read-only` forms).
Remove additional folders or explicitly choose `workspace-write` in the agent preset.
Native configuration and managed policy can also affect effective permissions;
the CLI still enforces them. Ordinary sessions retain their configured permissions.
Delegated orchestration workers explicitly use native YOLO mode, as described in
[orchestration validation](orchestration-validation.md); this does not change presets
or the coordinating session.

`Prototypes/real_checkout_recovery.py` verifies a moved main repository,
replacement primary/additional Git metadata, restored-checkout resume with actual
conversation recall, live-removal refusal, and clean removal preserving the
branch. It passed with Codex 0.154.0 and Claude Code 2.1.273 in basic-terminal
mode, using authorized private profile clones. Hook evidence is recorded
separately below; full coordination remains unverified.

`Prototypes/real_repository_access.py` also passes on these versions using the
signed Release runtime. Real tools read and write the selected primary worktree
and additional repository, including paths with spaces. The main checkout is
not added to the launch and remains unchanged, as does a sibling worktree.
Killing and restarting only the private runtime preserves the real CLI process,
conversation and recorded launch; both providers complete another tool-using
turn after recovery. Claude uses explicit basic-terminal mode. This does not
claim OS sleep/wake or LaunchAgent-update coverage.

`Prototypes/real_terminal_controls.py` uses the same authorized clones in a
signed isolated Debug app. Both current CLIs pass native trust prompts, Unicode
typing, copy/paste, resize, normal/forced UI quit, preserved unsent input and
same-process reattachment, followed by another provider reply. Unicode replies
are searchable and copyable from their captures. Native link/mouse forwarding and
sustained bounded-history rotation have separate fixture evidence in
[implementation status](implementation-status.md). Final workload coverage is
deferred to V2.

`Prototypes/native_attention_smoke.py` passes with Codex 0.154.0 and Claude Code
2.1.273 in an isolated signed Debug app. Each session makes one authenticated,
read-only discovery call with native one-time approval. The app shows Claude's
permission request as **Needs attention**, clears it after tool use, and shows
**Turn finished** after the reply. Completion remains finished after the idle
notification interval. Both CLIs provide native conversation IDs and report
**Exited** after `/exit`. No messages or delegation are exercised. Claude
2.1.273 now has the candidate integration path, still labelled unverified.

Codex's status path is turn completion through `notify`. It does not
prove approval or input status; these remain unknown when no supported event is
available. Claude uses launch-scoped hooks, which may be affected by native trust
or managed policy. Silence and output volume never set completion.

The private native LaunchAgent lifecycle check also passes with Codex 0.154.0
and Claude Code 2.1.273: normal UI quit, launchd crash recovery, the Settings
restart button, bundled-helper replacement, and a real user-performed sleep/wake
cycle. Both providers reply afterward with the original conversation context,
unchanged process/terminal identities, and correct Unicode output. See
[service recovery](service-recovery.md#private-native-service-fixture).

The default Codex and Claude launch routes have real credential and scoped-stop evidence.
Cross-provider orchestration has the dated evidence above; broader release workload
coverage remains open. See
[V3](decisions/V3-mcp-and-status.md). Both baseline CLIs pass native metadata
discovery/isolation/removal checks for the optional
[Chauffeur skill](coordination-skill.md). File installation status does not
override CLI skill policies or establish model use of the guidance.

### Inbox reminders

Coordinated Claude Code and Codex sessions get a short "Chauffeur: N new inbox
messages" reminder through native hooks when mail arrives while they are busy:
after the next tool call (`PostToolUse`, including MCP tools), at the start of a
prompt (`UserPromptSubmit`), or as one continuation before the turn ends (`Stop`).
Reminders never include senders or bodies and never wake an idle session.

- **Claude Code** runs the hooks from Chauffeur's launch-scoped `--settings` file.
  Its TUI labels the one intended continuation "Stop hook error: Chauffeur: …";
  that label is Claude's, and the turn continues normally.
- **Codex** skips hooks it does not trust. Before each launch Chauffeur runs
  `codex app-server --stdio` in an empty temporary `CODEX_HOME`, reads
  `hooks/list`, and trusts exactly its own session-flag hooks with a whole
  `-c hooks.state={…}` map. Hashes are cached per executable, version and hook
  definition. The user's own trusted hooks keep running, untrusted ones stay
  skipped, and nothing is written to `~/.codex`. If `hooks/list` fails, times out
  or lists anything unexpected, the session launches without reminders and
  discovery reports "Inbox reminders unavailable for this Codex version".
- Codex still prompts "Hooks need review" at startup when the **user** has
  untrusted hooks of their own; "Continue without trusting" keeps Chauffeur's.
- Codex's title generator runs a side thread whose `notify` carries another
  thread ID. Chauffeur takes the native conversation from the trusted
  `SessionStart` hook instead.

`Prototypes/codex_inbox_hooks_smoke.py` and
`Prototypes/cross_provider_inbox_smoke.py` check these behaviors through the real
runtime and the real TUIs with local mock providers, so they need no accounts.

### Idle coordinators

- **Claude Code** starts a new turn when a background Bash command exits, and its
  `Stop` hook lists running `background_tasks`. Coordinators wait with
  `chauffeurctl wait-for-work` in the background and use no tokens meanwhile.
- **Codex** keeps background commands running but never starts a turn when one
  exits. With the result wake on (the default), Chauffeur types a one-line prompt
  into an idle Codex coordinator when a worker reports or stops. Otherwise the
  coordinator waits inside `chauffeur_inbox`.
- **Codex sandboxes** (`workspace-write`, `read-only`) block commands from the
  runtime socket. `wait-for-work` and progress auto-registration then fail with a
  fallback message; MCP tools and hooks are unaffected.

### Orchestrated follow-up turns

Automatic terminal submission checks provider identity, completion, live pane
identity, cursor state, and an empty recognized composer before every submission.
There is no version allowlist. Busy sessions, drafts, dialogs, and unknown composer
layouts are refused; the coordinator can close and replace a worker instead.
Delegated Claude launches disable prompt suggestions in launch-scoped settings
so ghost suggestions do not occupy the composer. Ordinary sessions keep their settings.

Worker completion is an attributed MCP result, separate from terminal submission
or native turn-finished status. Messages do not wake an idle agent; coordinators
wait for results while their turn remains active.

### OpenCode

OpenCode runs its own TUI in tmux, like the other agents. Each launch adds a configuration layer through `OPENCODE_CONFIG_CONTENT`;
nothing is written into the user's OpenCode configuration. See [V9](decisions/V9-opencode-integration.md) for the measured
behaviour and the rejected alternatives.

- **Identification:** a semver `--version` and `opencode serve` / `opencode acp` in `--help`, which OpenCode prints to stderr. No
  version is pinned.
- **Configuration:** OpenCode always reads `~/.config/opencode`. A team's OpenCode directory is passed as `OPENCODE_CONFIG_DIR`,
  which OpenCode loads as an extra layer on top of the global one, not as a separate profile. Setup therefore copies nothing into
  it.
- **Models:** models and providers, including local servers, come from the OpenCode configuration. Chauffeur suggests models from
  `opencode models` and doesn't check that a local server is running; OpenCode reports that error in its TUI.
- **Environment:** inherited `OPENCODE_*` variables are removed, as are provider credentials such as `OPENAI_API_KEY` and
  `ANTHROPIC_API_KEY`. A configuration that reads a key with `{env:OPENAI_API_KEY}` doesn't get it under Chauffeur; store the key
  with `opencode auth login` or in the configuration instead.
- **Status:** a bundled plugin reports session start, running, attention (permission and question dialogs, including a subagent's,
  and model errors) and turn end through `chauffeurctl`. Subagent sessions never change the session's status or conversation.
  Pressing Esc is not an attention state.
- **Blocked options:** `--pure` (disables plugins, and so status), `--mini`, `--no-replay` and `--replay-limit` (a different UI),
  and the options Chauffeur manages: `-s`, `-c`, `--fork`, `--prompt`, the server options, subcommands and the project argument.
- **Additional folders:** granted through `permission.external_directory`, since OpenCode has no `--add-dir`.
- **Auto-approve:** `--auto` approves anything the configuration doesn't explicitly deny. Delegated workers always get it.
- **Inbox reminders and waiting:** mail at turn end continues the turn once through the plugin, and mail during a turn is appended
  to the next tool result. An idle coordinator is woken by the plugin's own `wait-for-work` when a worker reaches a milestone, so
  it ends its turn while workers run. OpenCode's MCP client drops a call after about 300 s whatever its timeout, so
  `chauffeur_inbox` waits at most 240 s in OpenCode sessions.
- **Follow-ups:** the composer is recognized from the prompt box around the cursor, as described in V9.
- **Evidence:** `Prototypes/opencode_smoke.py` passes against the real runtime, OpenCode 1.18.32 and Claude Code 2.1.281 with
  scripted mock models: plugin loading from a data root with a space, permission and question attention (none under `--auto`),
  mid-turn and turn-end mail, an OpenCode coordinator waking once per result from an OpenCode and a Claude worker, a follow-up
  through the composer rule, resume with `-s`, `/new` taking the session over (mail and a later resume follow it), and the
  240 s inbox cap. `Prototypes/opencode_live_smoke.py` passes with a local
  Qwen3 14B (4-bit) served by `mlx_lm.server`: status, the adopted `ses_…` ID, a `chauffeur_discover` call and a bash command.
- **Tool names:** OpenCode shows MCP tools as `<server>_<tool>`, so Chauffeur lists its tools to OpenCode sessions without the
  `chauffeur_` prefix, and OpenCode shows the names the skills use.
- **Conversation switches:** OpenCode's server can't see which session the TUI shows, so the plugin follows the root session that
  last turned busy. `/new`, `/fork` and a session picked in `/sessions` move the Chauffeur session once the user prompts there.
- **Known limits:** any other root session that turns busy in the same OpenCode server (another attached client, a plugin that
  creates root sessions) takes the Chauffeur session over too. OpenCode reads skills from both `~/.claude/skills` and
  `~/.agents/skills`, so managed skills can appear twice there.
