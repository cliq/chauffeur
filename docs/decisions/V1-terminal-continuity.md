# V1 — terminal continuity

Status: fixture continuity passed; real CLI and AppKit rendering acceptance open.

## Decision

Use the plan's tmux fallback as the PTY owner, with a private Chauffeur socket and configuration. Use tmux's native terminal attachment protocol through a runtime-owned attachment PTY. SwiftTerm renders that byte stream in the app. This refines the proposed control-mode fallback: tmux itself generates the complete redraw and maintains modes, instead of requiring Chauffeur to reimplement a serializer for control-mode output.

SwiftTerm 1.20.0 was inspected at revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`. Several state fields required for a faithful serializer are internal (including origin mode, wraparound, insert mode, cursor visibility, saved state and normal/alternate buffers). Copying visible cells would not meet F4.4. SwiftTerm is the native view component.

The tmux server owns agent PTYs independently of both the UI and Chauffeur runtime. On runtime restart, Chauffeur inspects its private tmux inventory and matches recorded session name, pane ID and process ID. Positive matches can reconnect; missing ownership becomes Interrupted. A restart never replays an initial task.

## Evidence

Run `python3 Prototypes/terminal_continuity.py` with tmux 3.6a. The fixture verifies:

- Same process ID after killing the first terminal attachment.
- Output continues while detached.
- A new attachment redraws the current alternate screen and Unicode text.
- Partially typed input remains unsent and is preserved.
- Resize reaches the process (110 columns by 35 rows).

`Prototypes/runtime_smoke.py` exercises the promoted implementation through its actual IPC server. Tests use only private temporary tmux sockets and clean up their servers.

The Debug app probe also exercises actual SwiftTerm views across tabs and split
panes. UI tests exposed inherited worker-thread signal masks in the forkpty path:
blocked `SIGWINCH` caused intermittent resize failures, and blocked `SIGTERM`
could prevent attachment cleanup. `Prototypes/pty_signal_mask.c` reproduces this
by blocking resize/stop signals and ignoring interrupt in the spawning thread.
It failed before the fix and passes after the child resets its signal mask and
handlers with async-signal-safe C calls before `exec`.

The project layout owns attachment decisions. Stable session identities preserve
views when split panes move, and cancelled attachments cannot feed late output
into a newer view connection. See [V5](V5-macos-lifetime.md) for native probe scope.

## Remaining gate evidence

Both real CLIs must be exercised in the SwiftTerm view, including copy, paste, links, cursor/mouse modes, sustained scrollback rotation, UI force quit, and native prompts. The current capture API is a bounded text/ANSI export, not yet the persisted snapshot/retention system. These remain release gates; fixture success is not a claim that V1 is fully passed.
