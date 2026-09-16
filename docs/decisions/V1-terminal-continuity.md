# V1 — terminal continuity

Status: fixture continuity and native keyboard/clipboard/history controls pass.
Real Codex and Claude Code pass native prompts, Unicode, clipboard, resize,
history search, and normal/forced UI quit with the same process and draft.
Native links, mouse input and sustained bounded history rotation also pass with
isolated fixtures. Final workload/performance acceptance remains in V2.

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

`Prototypes/terminal_controls_smoke.py` drives two fixture terminals through
macOS keyboard events and Accessibility actions. It verifies Unicode and literal
hyphens, Control-B/Escape/Control-C delivery, selection and copy, bracketed paste,
Command-F search of normal history and the captured Unicode screen, read-only
history, session switching/split shortcuts, and Command-Q/relaunch preserving the
process and unsent input. The terminal previously had no element in the native
accessibility tree; live and history views now expose distinct focusable text
areas with displayed output and selection. Clipboard checks preserve the prior
clipboard in memory. Private artifacts are in `.build/terminal-controls-artifacts/`.

`Prototypes/real_terminal_controls.py` runs the same signed Debug app with real
Codex 0.154.0 and Claude Code 2.1.273, an authorized profile clone, and a temporary
Git repository. The actual trust prompts are accepted through native keyboard
input after checking the displayed temporary path. Each CLI receives two
text-only turns. Native selection/copy, Unicode typing/paste, an OS window resize
(119×39 to 95×32 terminal cells), normal UI quit, force quit, and subsequent
reattachment pass. The same CLI process retains an unsent draft through both UI
relaunches and answers it afterward. Each generated Unicode reply is searched
and copied from History at capture time; the full search string is absent from
the corresponding prompt, preventing prompt echoes from satisfying the check.
Private reports and screenshots are under `.local/terminal-native-{codex,claude}/`.
Claude runs in basic-terminal mode; this does not establish 2.1.273 hook support.

The real Codex trust screen exposed blank terminal cells as NUL characters in
Accessibility. They now become spaces, while wide-glyph continuation cells are
omitted. The native fixture explicitly draws a cursor-positioned gap and checks
that it reads as spaces without NUL characters.

## Link, mouse and retention evidence

Bounded versioned captures are now persisted, with global disk-budget cleanup,
normal-history plus alternate-screen capture, and a native read-only search
view. See [terminal history](../terminal-history.md) for the retention policy and
fixture evidence.

`Prototypes/terminal_pointer_smoke.py` drives actual native mouse events against
the signed Debug app. Shift-drag selection and copy work without sending input,
including while the fixture CLI tracks the mouse. Press, release, drag, and
wheel-up/down events reach that CLI with their SGR mouse encoding. Command-click
opens both ordinary URLs and OSC 8 labeled links through the real OS URL handler;
a unique local HTTP listener verifies the resulting browser request. No provider
account or default runtime is involved. Evidence:
`.build/terminal-pointer-artifacts/`.

The OSC 8 check failed before the fix: tmux's default `xterm-256color` client
features did not include hyperlinks. Every attachment now passes `-T hyperlinks`,
which enables SwiftTerm's supported link capability without changing an agent's
environment or requiring a new tmux server.

`Prototypes/history_rotation_smoke.py` writes 60,000 plain/styled Unicode lines
with the UI detached and observes six advancing periodic archives. The tmux
history and encoded captures stay within their configured line/byte bounds;
unchanged captures retain their timestamp. The same fixture process survives a
runtime restart, and saved output survives tmux loss. See
[retention verification](../terminal-history.md#verification).

Together with the real CLI reattachment checks above, this establishes the V1
terminal continuity gate for the recorded versions and tmux ownership approach.
The provider runs use two short text-only turns. These checks do not establish
the deferred final workload/performance results or exhaustive provider UI behavior.
