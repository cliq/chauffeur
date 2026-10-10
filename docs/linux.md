# Linux server

- Date: 2026-10-10
- Status: the headless runtime (`ChauffeurRuntime`) and `chauffeurctl` build and run on Linux
  with Swift 6.2 or later (tested on Ubuntu 24.04, arm64). There is no desktop
  app on Linux: the iPhone app and the Mac app ([remote servers](remote-host.md)) pair with the
  runtime and drive it over the same TLS connection as [mobile remote control](mobile-remote.md).

## Installing

```sh
sudo apt-get install libssl-dev libsqlite3-dev tmux git python3
# Swift 6.2 or later, for example through swiftly (https://www.swift.org/install/linux/).
Scripts/linux/install.sh      # release build, ~/.local/lib/chauffeur, systemd user service
Scripts/linux/pair.sh         # turns on remote access and prints a pairing code
```

`install.sh` builds with a static Swift runtime, so the binaries only need the system's OpenSSL
and SQLite. It installs to `~/.local/lib/chauffeur`, links `chauffeurctl` into `~/.local/bin`,
and writes `~/.config/systemd/user/chauffeur.service`. Rerun it to update: the unit uses
`KillMode=process`, so agents in tmux survive a runtime restart. A user service stops at logout
unless lingering is on (`sudo loginctl enable-linger $USER`); the script says so when it isn't.

Data lives in `$XDG_DATA_HOME/chauffeur` (default `~/.local/share/chauffeur`; `chauffeur-debug`
for Debug builds). Release builds listen on port 51847 and pair on 51848, as on macOS.

Projects and teams have no editor on Linux. Create them with `chauffeurctl request saveProject`
and `savePresetSet` (see the record types in `Sources/ChauffeurCore/Records.swift`). Switching a
team to `"agentSelection": "custom"` copies every base agent into it; archive the unwanted ones
with `savePreset` and `"archived": true`.

## How it differs from macOS

| Area | macOS | Linux |
| --- | --- | --- |
| Remote TLS (TLS 1.2, `PSK-AES128-GCM-SHA256`) | Network.framework | `CChauffeurTLS`, over the system OpenSSL. BoringSSL (swift-nio-ssl) lacks this suite. |
| CryptoKit | CryptoKit | swift-crypto |
| Logging | `os.Logger` | stderr, which the journal records; same privacy redaction |
| Metadata and progress watching | FSEvents | inotify |
| Running commands | Foundation `Process` | `chauffeur_spawn` (posix_spawn) and `waitpid` |
| Keep awake | IOKit power assertion | `systemd-inhibit` |
| Desktop notifications | helper app | none |
| Service | LaunchAgent | systemd user unit |
| Exclusive rename | `renameatx_np` | `renameat2(RENAME_NOREPLACE)` |
| Worktree creation time | `st_birthtime` | `statx(STATX_BTIME)` |
| Executable paths | `_NSGetExecutablePath`, `proc_pidpath` | `/proc/self/exe`, `/proc/<pid>/exe` |

`Package.swift` declares only the runtime, `chauffeurctl` and their tests on Linux. Every
dependency stays declared, so `Package.resolved` is the same on both platforms; the first Linux
resolve therefore also fetches SwiftTerm and the Ghostty binary, which Linux never builds.

Platform differences live in `Platform`, `POSIX` and `Inotify` (ChauffeurCore), the C helpers in
`CChauffeur`, the files named `+Linux` or `Linux`, and whole per-platform implementations of one
type (the metadata and progress watchers, the power assertion). Keep other code free of
`#if os(Linux)`.

### Why commands don't use Foundation's `Process` on Linux

- swift-corelibs-foundation learns that a child exited through a socket the child inherits. A
  child that daemonizes, such as the tmux server `new-session` starts, keeps it open, so the
  command never finishes and its pipes stay open. That exhausted the descriptor limit within
  minutes.
- The child inherits the calling thread's signal mask, and Swift concurrency threads block most
  signals. A tmux server started that way never sees SIGCHLD and never reaps dead panes.

`chauffeur_spawn` starts children with no signals blocked, default signal actions and only the
standard descriptors, and `ProcessRunner` is their only reaper.

### SIGPIPE

Linux has no `SO_NOSIGPIPE`. Unix-socket writes use `MSG_NOSIGNAL`, and the runtime installs a
no-op SIGPIPE handler for OpenSSL's socket writes. A handler rather than `SIG_IGN`: exec resets
handlers, while an ignored SIGPIPE would carry into every shell and agent.

## Building and testing on a Mac

The Linux build and tests run in a container. Build an image with the packages above once:

```sh
printf 'FROM swift:6.2-noble\nRUN apt-get update && apt-get install -y libssl-dev libsqlite3-dev tmux git python3 zsh sqlite3\n' \
  | docker build -t chauffeur-linux -
docker volume create chauffeur-linux-build
docker run --rm -v chauffeur-linux-build:/build chauffeur-linux chown "$(id -u)" /build
```

Then, from the repository:

```sh
docker run --rm --user "$(id -u)" -e HOME=/tmp -v "$PWD":/src -v chauffeur-linux-build:/build -w /src chauffeur-linux bash -c \
  'cd /tmp && git config --global user.name Test && git config --global user.email test@example.com &&
   git config --global init.defaultBranch main && cd /src &&
   swift build --scratch-path /build --product chauffeurctl && swift test --scratch-path /build --no-parallel'
```

Use a separate `--scratch-path` so the Linux build doesn't overwrite the macOS `.build`. Run the
tests as a regular user (`--user`): as root, permission checks always pass. `ChauffeurRuntimeTests`
leaves out the two suites that drive the runtime through the Apple-only remote client.

## Limitations

- No desktop notifications.
- inotify watches count against `fs.inotify.max_user_watches`. Past the limit the metadata store
  falls back to rescanning.
- On file systems without a creation time, a removed and recreated worktree at the same inode
  can be mistaken for the old one.
- Keep awake needs logind to allow the user's sleep inhibitor; otherwise the status reports why
  it failed.
- Each remote connection uses two threads; fine for a few devices, not for many.
