# Chauffeur

A native macOS environment for running Codex and Claude Code across projects,
profiles, worktrees, and isolated communication groups.

**Implementation in progress.** The repository builds a SwiftUI/AppKit app,
background runtime, shared core, and command-line helper. Real CLI integration
and release acceptance remain open. See the [implementation status](docs/implementation-status.md),
[plan](docs/mvp-implementation-plan.md), and [PRD](docs/mvp-prd.md).

## Build the app

Development requirements: macOS 15+, Xcode 26.3 / Swift 6.2, XcodeGen, Git,
and tmux available in the user's login environment. The current app build targets
Apple Silicon.

```sh
Scripts/build-app.sh
open build/Build/Products/Debug/Chauffeur.app
```

The script generates the Xcode project, builds the native app, embeds its runtime
and helper, and signs the bundle locally. Use `Scripts/build-app.sh Release` for
an optimized local build. Developer ID signing and notarization are separate
release work.

The build explicitly allows the pinned SwiftTerm build plugin, which generates
Swift version metadata from that checkout's Git revision. Its plugin and generator
sources were inspected before enabling this per-command build flag. Dependencies
are pinned in `Package.resolved` and `project.yml`.

The app registers its bundled per-user LaunchAgent with `SMAppService`. If macOS
requires approval, the service health line links to Login Items & Extensions.
Registration and separate-Spaces acceptance are still under validation.

## Verify

Python 3 is required for the fixture scripts.

```sh
swift test
clang Prototypes/pty_signal_mask.c Sources/CChauffeur/CChauffeur.c \
  -I Sources/CChauffeur/include -o .build/pty-signal-mask
.build/pty-signal-mask
python3 Prototypes/terminal_continuity.py
python3 Prototypes/runtime_smoke.py
python3 Prototypes/native_window_smoke.py
```

Fixtures use temporary data, private tmux servers, and fake CLI processes. The
native probe uses the built Debug app and stores reports/images under
`.build/native-probe-artifacts/`. Xcode also includes `ChauffeurAppUITests` for
OS-driven UI testing, which requires macOS automation access.

## Start using a development build

1. Open Settings and create a preset set, then add presets selecting existing
   Codex or Claude Code configuration directories and their executables.
2. Create a project, choose its preset set, and register folders or discover Git
   repositories under a parent folder.
3. Open a project and create a session. Choose a group, preset, checkout, and any
   additional repository paths. Shared checkouts require an explicit choice.
4. Use tabs and a two-pane split to work with terminals. Session Details shows
   launch paths, process identity, messages, delegations, and stop/resume actions.

Closing a terminal tab, project window, or quitting the UI keeps agents running.
Stop Session ends an execution. Resume Conversation uses its recorded native ID
and original profile; it creates a new execution.

Real-account isolation, Codex backend ownership, native hooks and MCP connections
remain unverified. Matching a candidate CLI version enables experimental
integration; other versions offer explicit basic terminal mode. See
[compatibility](docs/compatibility.md) and [V3](docs/decisions/V3-mcp-and-status.md).

## Inspect the runtime

```sh
.build/debug/ChauffeurRuntime
.build/debug/chauffeurctl status
.build/debug/chauffeurctl snapshot
.build/debug/chauffeurctl help
```

Run the helper in another terminal when starting the runtime directly. Use
`--data-dir /absolute/path` on the runtime and
`--socket /absolute/path/runtime/runtime.sock` on the helper to isolate development
data. The default is `~/Library/Application Support/Chauffeur`; only one runtime
can own it.

Chauffeur uses its own tmux socket. A runtime restart reconciles recorded
pane/process identities; missing ownership becomes Interrupted. Metadata files
are human-readable JSON. External changes reload independently of the UI, and
stale saves report a conflict with the affected path.

Use **History and Search** or **Command-F** for retained terminal output, including
ended sessions. Settings controls line, disk and completed-message limits. See
[terminal history and recovery](docs/terminal-history.md) for defaults, cleanup
and service-loss behaviour.
