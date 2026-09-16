# Chauffeur

A native macOS environment for running Codex and Claude Code across projects,
profiles, worktrees, and isolated communication groups.

**Personal-use Release ready for testing.** The current scoped implementation and
focused native acceptance checks are complete, including real Codex/Claude
service recovery and sleep/wake. The repository builds a SwiftUI/AppKit app,
background runtime, shared core, and command-line helper. See the
[implementation status](docs/implementation-status.md),
[plan](docs/mvp-implementation-plan.md), and [PRD](docs/mvp-prd.md).
Completion of Codex ↔ Claude messaging/delegation and final workload testing are
planned for [V2](docs/v2-plan.md) and are outside the current goal.

The [app manual on Artifact Colab](https://artifacts.cliq.dev/d/DPu8kdqJdE) covers
every implemented screen and workflow, with keyboard shortcuts and current
limitations. It is private to its owner and accepted collaborators. The
[self-contained HTML source](docs/manual.html) also opens locally in a browser.

For development continuity, start with the [next-session handoff](docs/handoff.md).

## Build the app

Development requirements: macOS 15+, Xcode 26.3 / Swift 6.2, XcodeGen, Git,
and tmux available in the user's login environment. The current app build targets
Apple Silicon.

```sh
cp Configuration/LocalSigning.xcconfig.example Configuration/LocalSigning.xcconfig
# Set DEVELOPMENT_TEAM and any signing/bundle overrides in the local file.
make build
open 'build/Build/Products/Debug/Chauffeur Debug.app'
```

`make build` (or just `make`) generates the Xcode project, builds the native app,
embeds its runtime and helpers, and signs and verifies the complete bundle.
Use `make release` for an optimized build at
`build/Build/Products/Release/Chauffeur.app`. `make open` opens the generated Xcode
project, `make test` runs Swift package tests, and `make test-ui` runs native UI tests.

Debug and Release can run side by side. Debug builds use `Chauffeur Debug.app`,
the `.debug` bundle-ID suffix, the `dev.chauffeur.debug.runtime` service, and
`~/Library/Application Support/Chauffeur Debug`. Release keeps `Chauffeur.app`,
`dev.chauffeur.runtime`, and the existing `~/Library/Application Support/Chauffeur`
store. Notifications, logs, URL schemes, preferences, and installed terminal
commands are also separate (`chauffeur-debug` versus `chauffeur`).

Startup refreshes service registration after the app moves or its runtime changes.
The app verifies the connected runtime's build, executable location/hash, and data
directory before accepting its state. Runtime settings show the verified helper
path. Explicit `CHAUFFEUR_SOCKET` connections bypass managed-service verification
and are labeled as custom connections.

`Configuration/Base.xcconfig` defines the shared signing defaults and
`APP_BUNDLE_ID` (`dev.cliq.chauffeur`). Both Debug and Release include the optional,
gitignored `Configuration/LocalSigning.xcconfig`, following the same pattern as
Claude Monitor. The app and UI-test bundle identifiers derive from `APP_BUNDLE_ID`.
The default identity is Apple Development. To use an installed Developer ID
certificate for a persistent background service, add these local overrides:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Developer ID Application: Your Name (YOUR_TEAM_ID)
```

For an ad-hoc build without a development team or certificate:

```sh
make release XCODEBUILD_ARGS='CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-'
```

Service update checks use the same certificate for Debug and Release builds.
Ad-hoc builds remain useful for isolated fixture tests; changing ad-hoc helper
signatures can trigger macOS launch-constraint failures. The Makefile uses Xcode's
resolved identity for the app and every embedded helper. Builds are not notarized
or published.

The build explicitly allows the pinned SwiftTerm build plugin, which generates
Swift version metadata from that checkout's Git revision. Its plugin and generator
sources were inspected before enabling this per-command build flag. Dependencies
are pinned in `Package.resolved` and `project.yml`.

The app registers its bundled per-user LaunchAgent with `SMAppService`. If macOS
requires approval, the service health line links to Login Items & Extensions.
See [service setup and recovery](docs/service-recovery.md) for startup issues,
replacing a development build and the actual LaunchAgent acceptance probe.
The final separate-Spaces workload is deferred to V2.

Optional [session notifications](docs/notifications.md) run through an embedded
background app and open the selected project/session, including a cold app launch.
Enable them in Settings → Runtime; macOS notification permission is separate.

The [terminal launcher](docs/terminal-launcher.md) opens a project from a folder:
install it in Settings → Runtime, then run `chauffeur` or `chauffeur /path/to/folder`.

## Verify

The Python integration fixtures require Python 3.11 or newer (including its
standard-library TOML parser).

```sh
make test
clang Prototypes/pty_signal_mask.c Sources/CChauffeur/CChauffeur.c \
  -I Sources/CChauffeur/include -o .build/pty-signal-mask
.build/pty-signal-mask
python3 Prototypes/terminal_continuity.py
python3 Prototypes/runtime_smoke.py
python3 Prototypes/worktree_smoke.py
python3 Prototypes/native_window_smoke.py
python3 Prototypes/folder_launcher_smoke.py
python3 Prototypes/release_startup_smoke.py
python3 Prototypes/service_installation_smoke.py
```

Fixtures use temporary data, private tmux servers, and fake CLI processes. The
native probe uses the built Debug app and stores reports/images under
`.build/native-probe-artifacts/`. Xcode also includes `ChauffeurAppUITests` for
OS-driven UI testing, which requires macOS automation access.
Keep native test inputs and app-written reports in the temporary fixture directory,
not in the source checkout: this repository may live under macOS's protected
Documents folder. The test runner stages fake executables there and copies reports
back afterward. Start test processes with that directory as their working directory.
This avoids unnecessary Documents permission prompts for fresh test app identities;
accessing real repositories in protected folders still requires normal permission.

The launcher and Release startup checks use separately signed app copies and
isolated runtimes; they require the development machine's Leonardo Lobato
Developer ID certificate. The Release check verifies that the actual GUI opens.

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

1. Open Settings and create a team, then add agent presets selecting existing
   Codex or Claude Code configuration directories and their executables.
2. Create a project, choose its team, and register folders or discover Git
   repositories under a parent folder.
3. Open a project and create a session. Choose a group, agent preset, checkout, and any
   additional repository paths. Shared checkouts require an explicit choice.
4. Select a repository's checkout in the sidebar to see its sessions, launch an
   agent there, or open a shell. Session Details shows
   launch paths, process identity, messages, delegations, and stop/resume actions.

Optionally install the [Chauffeur coordination skill](docs/coordination-skill.md)
from **Settings → Agent Presets → Chauffeur Skill…**. Installation applies to all
sessions using that profile and can be removed from the same sheet.

Closing a project window or quitting the UI keeps agents running.
While the bundled service is running, a chauffeur-cap icon stays in the macOS
menu bar. Click it to see projects with active sessions and reopen a project,
selecting its last-selected live session (or its oldest live session). The menu
updates every two seconds and remains available with notifications disabled.
Its Quit command closes the main app while keeping sessions and the menu running.
Standalone runtimes using a custom data directory do not show the menu.
Stop Session ends an execution. Resume Conversation uses its recorded native ID
and original profile; it creates a new execution.

Real Codex and Claude checks cover two profiles each, shared-profile credentials,
native completion, messages and scoped process ownership. Both supplied Claude
profiles use the same account; the different-account Claude check was deferred
by the user. Full coordination/tool acceptance remains in V2. Matching a candidate CLI version enables experimental
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
