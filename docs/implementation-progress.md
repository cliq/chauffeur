# Session progress panels

Chauffeur bundles `implementation-progress` in
`Sources/ChauffeurCore/Resources/Skills/implementation-progress` and auto-installs
it beside its coordination skills. The managed catalog includes `SKILL.md`, the
Python CLI, and the HTML template. No separate skill installation is needed.

Run the bundled `scripts/progress.py` to initialize or update a panel. The script
publishes its standalone HTML, `progress.json`, and `progress.js`, then registers
the panel in the current session’s **Progress** tab. This works with **Enable
Chauffeur messaging and delegation** turned off: it uses the local Unix socket
and the agent’s session credential, not MCP.

Registration is attempted after every successful CLI command, including `show`
and `open`, so the next command retries a failed connection. Repeated registration
is idempotent. Failed registration never discards the local panel or prevents
updates; the script prints a warning. Without a session credential it continues
as a standalone browser panel. Use `--open` when a separate browser is wanted.
Default panel paths include the session ID inside Chauffeur so agents sharing a
checkout do not overwrite one another. An explicit `--dir` or `PROGRESS_DIR`
still takes precedence.

## Registration API

The local IPC methods `registerProgress` and `unregisterProgress` accept:

```json
{
  "token": "<current session credential>",
  "arguments": {
    "jsonPath": "/absolute/panel/progress.json",
    "htmlPath": "/absolute/panel/index.html"
  }
}
```

For removal, `arguments` is `{}`. The script reads `CHAUFFEUR_SOCKET` and
`CHAUFFEUR_SESSION_TOKEN` from its inherited environment and sends the credential
only over that local connection, never as a command argument or in panel files.
The runtime authenticates the live session before reading files and rechecks the
grant after those reads. Callers cannot select another session.

The existing MCP tools `chauffeur_register_progress` and
`chauffeur_unregister_progress` remain available for other panel producers; their
arguments are the inner `arguments` object above and their credential comes from
MCP authentication. Both transports use the same validation and persistence.

`jsonPath` is required; `htmlPath` is optional. Paths are on the runtime’s host,
not a remote client’s device. Registration validates JSON and any supplied HTML
before replacing the association. The result contains `sessionID` and `progress`
(the normalized paths).

The association is stored with the session and is returned by
`chauffeur_discover` as `progress`, or `null` when absent. Repeating a registration
is safe. Register new paths to replace it. Call `chauffeur_unregister_progress`
with `{}` to remove the association; neither replacement nor removal deletes
the files. Normal session retention still applies, and temporary panel files
can be removed by the OS.

The macOS details sidebar has Session Details and Progress tabs. Progress loads
the registered HTML in a WebKit view, allowing access to its containing directory
for `progress.js`. The HTML refreshes its data every two seconds. Chauffeur also
polls the JSON and HTML availability every two seconds while this tab is visible,
reopening files by path so atomic replacements are observed. An unavailable HTML
file falls back to the JSON view. Unreadable JSON reports an error and retains
the last readable JSON snapshot, if any, while retrying. Session changes reset
the displayed panel. No server is required.

## JSON version 1

```json
{
  "schemaVersion": 1,
  "percentComplete": 25,
  "title": "Feature implementation",
  "subtitle": "Implementation progress",
  "now": "Making changes",
  "updated": "2026-09-22T12:00:00+02:00",
  "phases": [
    {"title": "Build", "detail": "Implement the feature", "state": "active", "steps": []},
    {"title": "Verify", "detail": "Run checks", "state": "pending", "steps": []}
  ]
}
```

Phase and step states are `pending`, `active`, `done`, or `blocked`. Each step
has `title` and `state`. `updated` is an ISO 8601 timestamp. The percentage is an
integer from 0 to 100: done phases contribute one, active phases contribute the
fraction of completed steps (or one half without steps), and other phases
contribute zero. Divide by the phase count and round to the nearest integer,
with ties rounded up. Zero phases gives zero. This preserves the original HTML
estimate, including its handling of done phases containing blocked steps.

Chauffeur accepts legacy JSON without `schemaVersion` or `percentComplete`,
calculating the estimate when missing. Unknown fields are ignored; unknown schema
versions and states, invalid timestamps, and invalid percentages are rejected.
JSON and HTML files must be regular files no larger than 1 MiB. Each JSON and JS
write is atomic, but the two files can briefly represent adjacent updates.

The same association supplies the authenticated remote progress API and iPhone
progress display. Registration does not enable coordination tools or change the
session’s task-completion state.

## Verification

```sh
python3 -m unittest discover -s Tests/ImplementationProgressTests
swift test --no-parallel --filter 'ImplementationProgressTests|ProgressRegistrationTests|SkillInstallerTests'
```

The runtime integration test launches a fixture agent with coordination disabled,
executes the auto-installed script through its discovery symlink, and checks the
registered paths and subsequent updates. Installer tests cover publishing and
updating the script and HTML along with the skill instructions. Python tests cover
standalone use, session-specific directories, IPC framing, and graceful failure.
