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
an optimized local build. The default signature is ad hoc. For a persistent
background service, select a certificate already available to `codesign`:

```sh
CHAUFFEUR_SIGN_IDENTITY="Developer ID Application: Your Certificate Name" \
  Scripts/build-app.sh Release
```

Service update checks use the same certificate for Debug and Release builds.
Ad-hoc builds remain useful for isolated fixture tests; changing ad-hoc helper
signatures can trigger macOS launch-constraint failures. The build script verifies
the complete signed bundle. It does not notarize or publish the app.

The build explicitly allows the pinned SwiftTerm build plugin, which generates
Swift version metadata from that checkout's Git revision. Its plugin and generator
sources were inspected before enabling this per-command build flag. Dependencies
are pinned in `Package.resolved` and `project.yml`.

The app registers its bundled per-user LaunchAgent with `SMAppService`. If macOS
requires approval, the service health line links to Login Items & Extensions.
See [service setup and recovery](docs/service-recovery.md) for startup issues,
replacing a development build and the actual LaunchAgent acceptance probe.
Separate-Spaces acceptance remains open.

## Verify

The Python integration fixtures require Python 3.11 or newer (including its
standard-library TOML parser).

```sh
swift test
clang Prototypes/pty_signal_mask.c Sources/CChauffeur/CChauffeur.c \
  -I Sources/CChauffeur/include -o .build/pty-signal-mask
.build/pty-signal-mask
python3 Prototypes/terminal_continuity.py
python3 Prototypes/runtime_smoke.py
python3 Prototypes/worktree_smoke.py
python3 Prototypes/native_window_smoke.py
```

Fixtures use temporary data, private tmux servers, and fake CLI processes. The
native probe uses the built Debug app and stores reports/images under
`.build/native-probe-artifacts/`. Xcode also includes `ChauffeurAppUITests` for
OS-driven UI testing, which requires macOS automation access.

`python3 Prototypes/skill_installation.py` checks the real CLIs' skill metadata
using fresh fixture profiles, with no inference prompt. See the
[coordination skill guide](docs/coordination-skill.md) for scope and installation
checks.

The separate real-provider check requires two existing authenticated **test
clones**, with unrelated hooks/plugins/MCP servers disabled. It sends six small
fixture messages using the profiles' native model settings and grants one-time
approval only to those exact tool calls:

```sh
python3 Prototypes/real_codex_integration.py \
  --profile-a /path/to/private/codex-a --profile-b /path/to/private/codex-b
python3 Prototypes/real_claude_integration.py \
  --profile-a /path/to/private/claude-a --profile-b /path/to/private/claude-b
```

Redacted results and private failure artifacts are written under
`.local/real-codex-artifacts/` and `.local/real-claude-artifacts/`. Claude's
`--startup-only` option verifies native account displays and process configuration
without an inference prompt. Do not include private terminal/history files in
shared diagnostics. See [V3](docs/decisions/V3-mcp-and-status.md) for verified scope.

## Start using a development build

1. Open Settings and create a preset set, then add presets selecting existing
   Codex or Claude Code configuration directories and their executables.
2. Create a project, choose its preset set, and register folders or discover Git
   repositories under a parent folder.
3. Open a project and create a session. Choose a group, preset, checkout, and any
   additional repository paths. Shared checkouts require an explicit choice.
4. Use tabs and a two-pane split to work with terminals. Session Details shows
   launch paths, process identity, messages, delegations, and stop/resume actions.

Optionally install the [Chauffeur coordination skill](docs/coordination-skill.md)
from **Settings → Presets → Chauffeur Skill…**. Installation applies to all
sessions using that profile and can be removed from the same sheet.

Closing a terminal tab, project window, or quitting the UI keeps agents running.
Stop Session ends an execution. Resume Conversation uses its recorded native ID
and original profile; it creates a new execution.

Real Codex and Claude checks cover two profiles each, shared-profile credentials,
native completion, messages and scoped process ownership. Both supplied Claude
profiles use the same account; distinct-account selection and the remaining
native account/tool cases are pending. Matching a candidate CLI version enables experimental
integration; other versions offer explicit basic terminal mode. See
[compatibility](docs/compatibility.md) and [V3](docs/decisions/V3-mcp-and-status.md).

## Inspect the runtime

```sh
.build/debug/ChauffeurRuntime
.build/debug/chauffeurctl status
.build/debug/chauffeurctl diagnostics
.build/debug/chauffeurctl snapshot
.build/debug/chauffeurctl help
```

Run the helper in another terminal when starting the runtime directly. Use
`--data-dir /absolute/path` on the runtime and
`--socket /absolute/path/runtime/runtime.sock` on the helper to isolate development
data. The default is `~/Library/Application Support/Chauffeur`; only one runtime
can own it.

Use **Settings → Runtime → Export Diagnostics…** for a private report, including
cached state if the service is offline. Structured runtime logs rotate within a
2 MiB budget. See [diagnostics and redaction](docs/diagnostics.md) for included
fields, path privacy, storage locations, and limits.

Chauffeur uses its own tmux socket. A runtime restart reconciles recorded
pane/process identities; missing ownership becomes Interrupted. Metadata files
are human-readable JSON. External changes reload independently of the UI, and
stale saves report a conflict with the affected path.

Use **History and Search** or **Command-F** for retained terminal output, including
ended sessions. Settings controls line, disk and completed-message limits. See
[terminal history and recovery](docs/terminal-history.md) for defaults, cleanup
and service-loss behaviour.

Worktree inventory refreshes in the background. See [worktrees and cleanup](docs/worktrees.md)
for external moves, shared-checkout checks, safe removal, and recovery.
