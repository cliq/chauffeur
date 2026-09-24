# V9 — Integrate OpenCode through its own TUI and a launch plugin

Status: accepted after the verification spike of 2026-09-24, run against OpenCode 1.18.32 and a local MLX model.
The design is in [the OpenCode provider spec](../superpowers/specs/2026-09-24-opencode-provider-design.md). This record keeps the
facts the spike measured, and the places where they change the spec.

## Decision

Chauffeur runs `opencode` (the TUI) in tmux, like Claude and Codex. Each launch passes `OPENCODE_CONFIG_CONTENT`, which adds a
bundled Chauffeur plugin, the `chauffeur` MCP server and permission rules. The plugin reports status through `chauffeurctl`,
continues turns for new mail, and runs the coordinator waiter.

### Rejected options

- **Approach 2: headless `opencode serve` plus `opencode attach` in tmux.** It works: the attached TUI is equivalent, `/event`
  carries the same events, `prompt_async` shows in the attached TUI, and sessions resume by ID. It would only remove the
  screen-scraped composer rule, and it costs a second process, a port and a server password per session. `attach` also keeps
  running with a dead server and silently drops input, and it lacks `-m`, `--agent`, `--auto` and `--prompt`. It uses no less
  memory: about 650 MB for serve plus attach, against about 700 MB for one TUI.
- **ACP (`opencode acp`).** It drops the native TUI.

### Pivot conditions

Switch to approach 2 if the composer rule below proves unreliable for follow-ups in practice, or if `promptAsync` continuation
from `session.idle` stops starting visible turns. A cheaper step comes first: the plugin could long-poll Chauffeur for
follow-ups on idle and deliver them with `promptAsync`, like the waiter.

## Measured facts

### CLI

- `--version` prints a bare semver (`1.18.32`) on stdout.
- `--help` prints to **stderr**, so the capability probe must read stderr.
- OpenCode is identified by `opencode serve`, `opencode acp` and `opencode attach` in its help.
- The TUI accepts `-m`, `--agent`, `--auto`, `-s`, `-c`, `--fork`, `--prompt`, `--pure` and `--mini`.
  - `--prompt` submits automatically.
  - `--pure` disables `file://` plugins.
  - `--no-replay` and `--replay-limit` belong to mini mode and are blocked with `--mini`.
- `opencode models` prints one `provider/model` per line. It always includes OpenCode's free `opencode/*` models.
- Session IDs are `ses_` followed by 26 alphanumeric characters.

### Configuration

- Layers load in the order global (`~/.config/opencode`), then `OPENCODE_CONFIG_DIR`, then `OPENCODE_CONFIG_CONTENT`.
  - `plugin` arrays are concatenated, and the `mcp` and `provider` maps are merged.
  - `permission` keys from the content are added after the user's keys.
- **`OPENCODE_CONFIG_DIR` adds a layer. It does not replace the global directory.**
  - A team's OpenCode directory is an extra configuration layer, not a separate profile.
  - Configuration migration is a no-op: copying plugins into it would load them twice.
  - OpenCode writes `package.json`, `node_modules/` and `.gitignore` into every configuration directory it loads.
- `{env:VAR}` substitution works in MCP headers.
- `permission.external_directory` with `"<abs>/**": "allow"` grants additional paths without a prompt.

### MCP

- Tools are named `<server>_<tool>`, so Chauffeur's `chauffeur_inbox` is `chauffeur_chauffeur_inbox`. The end-to-end smoke
  found that a local model told to call `chauffeur_discover` called that name, got OpenCode's "unavailable tool" error and gave
  up. Texts that reach an OpenCode model (inbox hints, waiter prompts) therefore use the exposed names.
- Permission rules use the last match, so `chauffeur_*` must come after any `*` rule. The content's keys follow the user's.
- `mcp.<name>.timeout` (ms) controls the tool-call timeout. Without it, calls fail after about 60 s.
- **A plain JSON reply fails after about 300 s, whatever the timeout.** Only an SSE response with periodic keepalive comments
  survived 370 s.
  - Chauffeur caps `chauffeur_inbox` waits for OpenCode sessions at 240 s. An empty inbox reply already means "check and
    wait again".
  - The launch sets `timeout: 300000`.

### Plugin API and events

- A plugin is a named export `async ({client, directory, worktree, serverUrl, project, $}) => hooks`.
  - The `event` hook receives `{event: {type, properties}}`.
  - `client.session.promptAsync({path: {id}, body: {parts: [{type: "text", text}]}})` starts a new turn right away, and it
    shows in the TUI like typed input.
- `session.created`
  - Properties are `info.{id, parentID?, title, agent, directory}`.
  - Subagent sessions from the task tool carry `parentID`.
  - Resuming with `-s <id>` emits no `session.created`, so the plugin adopts the first root session ID it sees.
- `session.status`: `{sessionID, status: {type: "busy" | "idle" | "retry"}}`. It stays `busy` while a dialog is open.
- `session.idle`: `{sessionID}` only.
  - After `session.error` it arrives once or twice.
  - The plugin tracks child session IDs from `session.created` to filter it.
- `session.error`: `{sessionID, error: {name, data: {message}}}`.
  - `MessageAbortedError` is the user pressing Esc, not an attention state.
  - Any other error must survive the idle that follows.
- `permission.asked`: `{id: "per_…", sessionID, permission, patterns, metadata, always, tool}`.
  - `permission.replied`: `{requestID, reply: "once" | "always" | "reject"}`.
  - Under `--auto` the reply follows in about 13 ms, so attention is reported only when a request stays open for about 250 ms.
  - The `permission.ask` hook never fired.
- `question.asked`: `{id: "que_…", sessionID, questions}`. It is resolved by `question.replied` or `question.rejected`.
- `tool.execute.after(input, output)`
  - Built-in tools pass `output.output` (a string) that can be appended to.
  - MCP tools pass `output.content` (an array) that can be pushed onto.
  - Both reach the model. The hook doesn't run for failed calls.
- A plugin can spawn a long-running child without blocking. The child is orphaned if OpenCode dies.
  `chauffeurctl wait-for-work` already exits when its parent changes, and the plugin also kills it on dispose.

### Composer

The TUI draws the prompt as a box with a `┃` left bar, above an agent/model line and a `╹▀…` bottom edge. The active line is
`┃` both while busy and while idle. Only the footer's `esc interrupt` tells busy apart, and dialogs move the cursor into the
transcript. Readiness therefore reads the screen around the cursor, not only the active line:

- Ready when all of these hold:
  - the cursor line is `┃` alone, or `┃  Ask anything…` before the first turn
  - the cursor column is the bar column plus 3
  - the line above is `┃` alone
  - the next lines are `┃`, then an agent/model line, then the `╹▀` edge
  - no line below the box contains `esc interrupt`
- Input pending when the cursor line or the line above holds other text after `┃`.
- Unrecognized otherwise.

Bracketed paste, a pause, then a pasted carriage return submits the prompt, as `TmuxHost.submitFollowUp` already does.
