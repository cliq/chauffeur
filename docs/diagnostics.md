# Diagnostics and runtime logs

Choose **Settings → Runtime → Export Diagnostics…** to save a private JSON report.
The helper can also print the live report:

```sh
.build/debug/chauffeurctl diagnostics
# For an isolated development runtime:
.build/debug/chauffeurctl diagnostics --socket /absolute/path/runtime/runtime.sock
```

The app export is created with owner-only permissions (0600) and replaces the
destination atomically. The CLI prints to standard output; shell redirection
uses your shell's file permissions.

## What a report contains

- macOS and runtime versions, protocol version, runtime ID/state, and whether
  the local MCP endpoint is ready.
- Session/project/group/preset UUIDs, CLI kind, executable/version, configuration
  path, working directory, additional paths, process ID, session state, and typed
  failure/exit codes when available.
- Recent runtime and metadata error codes with relevant paths. Error messages
  are excluded because they can contain CLI output or user-entered text.
- Up to 200 structured runtime events and log availability. App exports also
  include app version, service registration state, and a numeric macOS error
  code with an allowlisted error-domain category.

The schema excludes credentials, environment values, launch arguments, complete
configuration files, tasks, titles, preset names, native conversation IDs,
messages, delegation results, and terminal history. Exports use explicit fields;
adding a field to a session record does not add it to diagnostics. Unknown error
codes become `operation_failed`. Recognized CLI version output is reduced to a
version number; other output is omitted.

**Paths can identify your macOS account and project folders.** The redaction
layer removes credential-like and opaque path components and rejects malformed,
configuration-like, or oversized paths. It cannot infer whether an ordinary
folder name is confidential. Review paths before sharing the report.

A report includes the 100 most recently updated sessions, at most eight
additional paths per session, and the last 100 errors. Omitted counts make these
limits visible. Paths are limited to 2048 UTF-8 bytes.

## Offline reports

The app first requests a live report. If the service cannot respond, it exports
the last snapshot received during this app run with `observation: cached` and
`observedAt`. Session state and MCP readiness then describe that timestamp;
they do not prove that a process is still running. Before any snapshot has been
received, the report says `unavailable`. Cached reports mark logs `notFetched`.

`chauffeurctl diagnostics` requires a responding service. It does not substitute
cached data. Existing `snapshot` output contains full local session/message
records and should not be used as a shareable diagnostic report.

## Structured logs

The default runtime writes to `~/Library/Logs/Chauffeur/`. A runtime using a
different `--data-dir` writes to `<data-dir>/runtime/logs/` so fixture runs remain
isolated. The directory is private (0700); managed files are private (0600).

`runtime.jsonl` rotates through `runtime.1.jsonl` to `runtime.3.jsonl`, with at
most 512 KiB per file (2 MiB total). Events contain timestamps, fixed event/error
codes, UUIDs, states, process IDs, exit statuses, tool names, and numeric counts. They have
no free-form text or path fields. Session state changes and authenticated MCP
tool calls can be correlated by session ID without recording tool arguments.

Log operations use a file lock across processes. They reject symlinks, hard
links, unexpected file types, and oversized existing managed files. Rotation
touches only the four named log files; unrelated files are preserved. Malformed
or unsupported log entries are omitted from exports and counted. Reading a log
reconstructs its typed fields; unknown JSON fields are never copied verbatim.

Logging failures leave sessions running and set log availability to
`unavailable` in a live report. Startup failures also emit a fixed error code to
the macOS system log and standard error. Logs are best-effort debugging evidence,
not a transaction audit or terminal transcript.

## Verification

- Swift tests cover field exclusion, hostile error/version/path text, legacy
  session decoding, report bounds, private atomic export, log rotation/reopen,
  malformed entries, and preservation of unsafe or unrelated files.
- `Prototypes/runtime_smoke.py` checks live socket and CLI exports against real
  fixture grants/messages, checks lifecycle and error codes, and verifies that
  a broken log destination leaves the service running and its target unchanged.
- The Debug native probe checks live, cached, and unavailable reports and writes
  an export while four project windows host ten fixture terminals. The native
  save dialog's OS-driven interaction remains part of XCUITest acceptance.
