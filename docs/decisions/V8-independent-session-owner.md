# V8 — Keep session privacy ownership independent

Status: implemented; installed Release acceptance on 2026-09-18.
Builds on [V7's measured TCC behavior](V7-session-privacy-attribution.md) and
preserves [V5's session lifetime](V5-macos-lifetime.md).

## Decision

New packaged-runtime sessions use **Chauffeur Sessions**, a Developer ID signed
LSUIElement app with identifier `dev.cliq.chauffeur.sessions`. Debug uses
`dev.cliq.chauffeur.debug.sessions`. LaunchServices starts it on demand. It owns
the creation of a fresh tmux server and remains alive independently of the
Chauffeur desktop app and background runtime. It is not another launchd service
or a separately registered login item. After login, the runtime starts it when
the first new session needs it.

This provides a stable app consent subject for tools, including ad-hoc Homebrew
binaries. The intended experience is persistent folder consent where macOS
supports it, and shared AppData consent for the original owner's lifetime.
It does not promise one permanent grant across all protected services. UI quit,
runtime restart and runtime stop preserve that lifetime. Logout, reboot or
explicitly stopping/crashing the Sessions app ends it. The current owner remains
alive even when its server has no sessions, to cover later sessions too.

## Launch, reconnect and update

The runtime verifies and copies the embedded signed app into a versioned,
private `session-apps/<fingerprint>/Chauffeur Sessions.app` inside its data root.
It verifies the copy and compares its executable and plist against the embedded
source. The fingerprint includes the signed executable and plist. Installation
can then replace `/Applications/Chauffeur.app` without deleting a live owner's
responsible executable. Cached apps are immutable and are not automatically
removed in this prototype, including after retirement.

A private `runtime/session-owners/<UUID>/manifest.json` names the app, tmux
executable, filtered environment and unique socket. The helper takes a lifetime
file lock, refuses any existing socket, starts tmux, sets an owner UUID on the
server, and publishes its PID. Reconnect requires the lock, matching executable
path for that PID, and matching server UUID. A serialized start task coalesces
concurrent launches. This is a same-user file handoff and tmux's private Unix
socket, not a new network command service. Session commands continue through
the existing private `chauffeurctl internal-exec` payload.

Only the helper may create a server in a packaged build. Runtime tmux clients
use `-N` to prevent an unnoticed fallback to runtime-owned server creation.
Missing/invalid helper bundles fail new launches while old sessions remain
accessible. Bare Swift development builds and unit-test fixtures retain the
direct backend.

An unchanged helper reconnects after runtime restart. A changed helper gets a
fresh owner and server; existing sessions stay with their original owner. Once
the replacement is ready, older owners receive a retirement marker. Each checks
its session count inside tmux and stops its own server only when empty; unknown
state never authorizes a stop. Dead panes retained for history count as sessions
until the runtime retires them. The signed cached bundle remains on disk.

Terminal inventory combines the legacy `runtime/tmux.sock` with all recorded
owner sockets. Attach, input, resize, activity, history, interrupt and stop route
to the server holding that session. Attachment generations remain global across
servers. A runtime restart reconstructs routing from tmux, without replaying
commands or migrating processes.

## Failure behavior and limits

A crashed owner cannot adopt its existing descendants when restarted. Its tmux
sessions survive and remain controllable, but AppData can prompt repeatedly
again. New sessions use a fresh owner/server. Sessions created before this
change also stay on their original server and keep their original attribution;
starting a new session is how to use the new owner. No live execution is killed
to repair privacy attribution.

A helper update starts a new consent lifetime even while the previous helper
continues serving its sessions. A Homebrew tool upgrade alone does not change
the helper's identity or lifetime. Actual Homebrew upgrades, reboot/login,
Desktop and Downloads consent are not part of this acceptance run. The V7
fixtures establish AppData's lifetime distinction; a responsible-PID check
alone is not a permission test. The existing main Chauffeur Full Disk Access
grant must not be treated as proof of ordinary Sessions consent.

Cache collection is deferred: never manually remove a cached app while its
owner or descendants remain. A tmux client that can no longer contact an old
server (including an incompatible tmux upgrade) causes an error or conservatively
retains an old helper; it is not evidence that sessions are safe to kill.

## Validation

- `swift test`: 275 tests passed; 31 affected tests passed again after the final
  routing/path review. Coverage includes real tmux routing across legacy and
  owner servers, attachment generation ordering, private owner-lock liveness,
  and missing-helper failure. Existing cancellation/attachment suites passed.
- `make install` signed, verified and installed Release. The required
  `launchctl kickstart -k gui/$(id -u)/dev.chauffeur.runtime` preserved the
  nine recorded live pane IDs and PIDs, including after the final reinstall. One Xcode intermediate-file attribute-copy
  error required retrying the build; the retry succeeded.
- `Prototypes/session_owner_acceptance.py` exercises the installed binary with
  an isolated LaunchAgent/data root. It checks shell and real Homebrew Python
  responsibility across normal UI quit keeping terminals, runtime kickstart,
  complete runtime stop/relaunch, a separately signed helper update, deletion
  of its embedded source, retirement after session drain, and an owner crash.
  Crash recovery also captures history from the surviving old server. A final
  installed run launched four sessions concurrently and confirmed that all
  share one owner, including after runtime stop/relaunch.

- With a signed sandbox fixture and an empty data-access allowlist, real Homebrew
  Python read one byte in five probes. TCC recorded **two AppData prompts**, both
  for `dev.cliq.chauffeur.sessions`: one for the original owner, one for the
  updated owner. New Python panes after runtime restart and complete
  stop/relaunch, and the original owner after an update, required no further
  AppData prompt. Access by the updated owner still worked after deleting its
  embedded source, because its cached bundle remained. An additional Documents
  prompt belonged to the deliberately relocated update-fixture runtime's login
  shell, not to Python or the Sessions helper. This is recorded separately from
  AppData consent; the installed main app's existing FDA did not substitute for
  the observed Sessions AppData prompts.

Private results are in `.local/sessions-implementation/`,
`.local/sessions-acceptance/`, `.local/sessions-final-acceptance/`, and
`.local/sessions-appdata-acceptance/`. The script cleans only its own unique processes,
sockets and files; it never resets TCC or answers privacy prompts.
