# Chauffeur

A native macOS environment for running Codex and Claude Code across projects,
profiles, worktrees, and isolated communication groups.

**Implementation in progress.** The repository currently builds the Swift runtime,
shared core, and command-line helper. The native app and release acceptance are
still being implemented. See the [implementation status](docs/implementation-status.md),
[plan](docs/mvp-implementation-plan.md), and [PRD](docs/mvp-prd.md).

## Build and verify the foundations

Requirements: macOS 14+, Swift 6.2, Git, tmux, and Python 3 for the fixture scripts.
XcodeGen is needed for the forthcoming app target.

```sh
swift build
swift test
python3 Prototypes/terminal_continuity.py
python3 Prototypes/runtime_smoke.py
```

Fixture tests create temporary data and private tmux servers, use fake CLI
processes, and clean them up. They do not use provider accounts. Dependencies
are pinned in `Package.resolved`.

## Inspect the development runtime

```sh
.build/debug/ChauffeurRuntime
```

In a second terminal:

```sh
.build/debug/chauffeurctl status
.build/debug/chauffeurctl snapshot
.build/debug/chauffeurctl help
```

Use `--data-dir /absolute/path` on the runtime and `--socket
/absolute/path/runtime/runtime.sock` on the helper to isolate development data.
The default is `~/Library/Application Support/Chauffeur`. The runtime refuses
another instance using the same directory.

Normal terminal detachment never stops an agent. The tmux server uses Chauffeur's
own socket and does not connect to a user's existing tmux server. A runtime
restart reconciles recorded pane/process identities; missing ownership becomes
Interrupted. Native conversation resume is explicit and never uses “latest”.

The adapters are under compatibility validation. Do not interpret fixture
success or a matching CLI version as proof of real-account isolation. See
[compatibility](docs/compatibility.md) and [V3](docs/decisions/V3-mcp-and-status.md).
