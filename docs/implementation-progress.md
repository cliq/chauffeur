# Session progress panels

The `implementation-progress` skill in `Skills/implementation-progress` maintains
its standalone HTML panel and publishes `progress.json` and `progress.js` after
each CLI update. Its installation is separate from Chauffeur's bundled skills.

An agent with Chauffeur MCP access registers an existing panel:

```json
{
  "jsonPath": "/absolute/panel/progress.json",
  "htmlPath": "/absolute/panel/index.html"
}
```

Call `chauffeur_register_progress` with these arguments. `jsonPath` is required;
`htmlPath` is optional. Paths are on the runtime's host, not a remote client's
device. Registration validates the JSON and any supplied HTML file before
replacing the session's previous association. Ownership comes from the MCP
credential; callers cannot select another session. The result contains
`sessionID` and `progress` (the normalized paths).

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

Native iOS presentation, Live Activities, remote progress transport, and a
terminal-side progress bar are future consumers, not part of this implementation.

## Verification

```sh
python3 -m unittest discover -s Skills/implementation-progress/tests
swift test --filter 'ImplementationProgressTests|ProgressRegistrationTests|SkillInstallerTests'
```
