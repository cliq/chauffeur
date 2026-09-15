# Terminal history and retention

Live terminals use tmux's current screen, modes, input and process. Closing the
app does not stop the terminal. Reopening a view attaches to that same process.
Use **History and Search** or **Command-F** to open a read-only capture with
scrolling, selection and search. **Refresh** requests a new capture when the
terminal still exists. Typing or pasting into history does not send agent input.

## Saved captures

The background runtime captures owned terminals roughly every five seconds and
on explicit history requests. It saves normal scrollback, the saved normal
screen when an alternate screen is active, and the current visible screen in
`runtime/snapshots/<session UUID>/latest.json` under Chauffeur's data directory.
Each version-1 file records its session/pane/process identity, dimensions, line
limit and capture time. Unchanged output keeps its existing file and timestamp.

Saved output retains text and ANSI colour/style codes. Clipboard, query, cursor
and other terminal controls are removed. Captures are private files (0600) in
private directories (0700); their text can contain anything printed in a terminal.
They are separate from native CLI conversations and configuration directories.

## Defaults and cleanup

| Setting | Default | Behaviour |
| --- | --- | --- |
| Scrollback | 10,000 lines | Keep the most recent complete history lines, plus the visible screen. Reducing this value trims saved captures. A live tmux buffer keeps its launch-time limit; new terminals use the new setting. |
| Snapshot budget | 256 MiB | Total encoded JSON bytes, with at most 4 MiB per capture. Remove ended/orphaned sessions first, oldest first; then remove the oldest live captures if needed. A large capture may retain fewer lines than the line setting. |
| Completed messages | 90 days | At startup, after a settings save and hourly, remove old acknowledged, cancelled and failed messages. Keep retry tombstones so an old retry cannot deliver duplicate work. |

Queued and received messages are never removed by message retention. Cleanup
does not visit native conversations, credentials, project files or worktrees.
Snapshot cleanup only removes Chauffeur's named `latest.json` files. Unknown
files and invalid/symlinked archives are preserved and reported as errors.
Storage usage shown in Settings counts encoded files, excluding filesystem
allocation overhead. Changing settings does not truncate an existing live tmux
buffer or its active screen.

After an execution ends and its history is captured, the runtime retires its
dead tmux pane. The retirement command checks the pane ID and process ID together
with the dead flag, protecting a newly resumed execution from delayed cleanup.

## Service loss and recovery

- If only Chauffeur or its runtime closes, surviving tmux terminals reconnect by
  their recorded ownership. A runtime restart does not resend the initial task.
- If tmux is lost, the session becomes **Interrupted**. History still shows the
  last retained capture and its timestamp. Output since that capture may be lost.
  An evicted capture cannot be recovered by Chauffeur.
- **Resume Conversation** is an explicit action and requires a recorded native
  conversation ID. Saved terminal text is not a conversation-resume mechanism.
- An invalid saved capture is preserved. The error identifies its path; move
  that file aside if you want a still-live terminal to create a fresh capture.
  Future-format snapshots require a compatible app version.

## Verification

`swift test` covers Unicode and ANSI sanitization, byte/line bounds, durable file
reopening and permissions, ended-first eviction, corrupt and symlinked files,
and queued/received message preservation. `Prototypes/runtime_smoke.py` checks
normal history alongside an active alternate screen, changed limits on an
existing tmux server, ended-pane retirement, and history after terminal/runtime
loss. The native Debug probe checks normal-history and active-screen search,
read-only input, and repeated UI quit/relaunch. Real CLI rendering acceptance
remains tracked in [V1](decisions/V1-terminal-continuity.md).
