---
name: implementation-progress
description: Create and maintain an auto-refreshing progress panel in Chauffeur’s session Progress tab or a standalone browser, showing implementation phases, optional steps, and current activity. Use when the user asks for a progress panel, dashboard, or status page for a multi-step task, or when updating a panel already in use.
metadata:
  version: "1.0.0"
---

# Implementation progress

Use `scripts/progress.py` next to this skill to maintain a small browser dashboard
while carrying out the user's task. It uses Python 3.8+ and the standard library;
no server, packages, API keys, or agent-specific tools are needed. Chauffeur bundles
and auto-installs this skill, including its script and HTML template. Inside a
Chauffeur agent session, commands automatically register the panel in that
session’s **Progress** tab, even when messaging/delegation MCP is disabled.
The page reloads `progress.js` every two seconds. Progress reflects your updates, not automatic
observation of tools or the repository.

## Locate the script and panel

Resolve `scripts/progress.py` relative to the directory containing **this loaded
SKILL.md**, whether installed by a plugin or as a standalone skill. Use its absolute
path for subsequent calls; do not assume a username, config directory, or shell's
working directory. Below, `P` means that script path and `DIR` means the panel output
directory. Use the available Python 3 command (`python3`, `python`, or `py -3`).

Choose a writable directory outside the repository and installed skill, preferably
the session's scratch directory. Pass the same absolute `--dir` on every call, even
after changing working directories or resuming the conversation. Keep the script
and panel paths in the task's handoff notes when needed. Shell variables in the
examples are shorthand; tool calls may not share a persistent shell.

Without `--dir`, the script uses `PROGRESS_DIR`, then the OS temporary directory
under `implementation-progress/<cwd-name>-<identity-hash>`. Inside Chauffeur the
identity includes the session ID, so concurrent sessions get different panels.
Outside Chauffeur, use distinct directories for concurrent tasks in one project. Have one agent write a given panel;
individual file writes are atomic, but simultaneous read/modify/write commands
can overwrite each other's changes.

## Start or resume

Adapt a handful of coarse phases to the user's actual plan:

```bash
python3 "$P" init --dir "$DIR" --title "Feature implementation" \
  --subtitle "Implementation progress" \
  --phase "Discovery::Understand requirements and existing code" \
  --phase "Implementation::Make the planned changes" \
  --phase "Verification::Run relevant checks and review the result" \
  --now "Reading the requirements"
```

The first phase starts `active`; the others start `pending`. Inside Chauffeur,
look for the script’s registration confirmation and tell the user the panel is
available in the session’s **Progress** tab. No separate registration tool call
or browser is needed. Outside Chauffeur, share the printed `index.html` path and
use `open` (or `init --open`) to launch its default browser. `--open` also works
inside Chauffeur if the user wants a separate browser window. If no browser is
available, the command prints a manual-open URI. Do not claim the user saw the
panel merely because launching was requested. In a remote or headless environment,
use `show` and explain that the page lives on that machine.

If a panel already exists, inspect it with `show` and use `open` to reopen it.
`init` refuses to overwrite progress unless `--force` is supplied. Use that flag
only when intentionally restarting the task; otherwise choose a new directory.

### Automatic Chauffeur registration

After each successful command, the script uses `CHAUFFEUR_SOCKET` and
`CHAUFFEUR_SESSION_TOKEN` inherited from the current agent session. The runtime
authenticates the credential and associates the absolute JSON and HTML paths
with that session. MCP access is not required. Never read another session’s
environment, pass credentials in command arguments, or copy them into the panel.

Registration is idempotent. Subsequent commands reassert the association, so
resuming with `show` or updating a panel also repairs a failed connection. A
connection failure leaves the local files usable, prints a warning, and retries
on the next command. Report that warning rather than claiming registration
succeeded. Without a session credential the script runs as a standalone tool.
Older Chauffeur runtimes may need an update/restart to support registration.

## Update at milestones

```bash
python3 "$P" now --dir "$DIR" "Running the integration tests"
python3 "$P" phase --dir "$DIR" 1 done
python3 "$P" phase --dir "$DIR" "Implementation" active
python3 "$P" step --dir "$DIR" 2 "Implement the new behavior" done
python3 "$P" step --dir "$DIR" 2 "Check error handling" active
python3 "$P" phase --dir "$DIR" 3 blocked --detail "Waiting for test credentials"
python3 "$P" show --dir "$DIR"
python3 "$P" open --dir "$DIR"
```

Phase selectors are 1-based indices or unique, case-insensitive title prefixes.
States are `pending`, `active`, `done`, and `blocked`. Steps are optional, added or
updated by case-insensitive title, and displayed under non-pending phases. Adding
a step activates a pending phase. Marking a phase done completes its non-blocked
steps; resolve blocked steps before treating the whole phase as complete. Changing
one phase does not automatically activate or complete any other phase.

Update `now` when the activity changes and phase/step states when they actually
change. The footer flags updates older than 20 minutes; do not invent progress to
clear the indicator. On completion, mark the finished phases done and describe the
outcome in `now`. If work stops early, preserve pending/blocked work and record why.

The percentage is a rough, equally weighted phase estimate: done phases count as
one; active phases count their fraction of done steps, or one half when they have
no steps. It is not elapsed time or an ETA.

## Files

The script writes `index.html`, `progress.json`, and `progress.js` to the panel
directory. Use the CLI rather than editing generated files. Keep these runtime
files out of commits unless the user explicitly wants an exported snapshot.
Temporary directories can be cleaned by the OS; use a persistent `--dir` if needed.

Other tools can read `progress.json`: `title`, `subtitle`, `now`, `updated`
(ISO 8601), and `phases[]` with `title`, `detail`, `state`, and `steps[]`
containing `title` and `state`.

New writes also include `schemaVersion: 1` and integer `percentComplete` (0–100),
using the same phase estimate and rounding as the HTML. Existing JSON files are
upgraded on the next CLI update. Readers should ignore unknown fields and reject
unsupported schema versions. The JSON and JavaScript each publish atomically;
they may briefly represent adjacent updates because they are separate files.
