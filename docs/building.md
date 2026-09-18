# Building, signing, and verifying

Development requirements: macOS 15+, Xcode 26.3 / Swift 6.2, XcodeGen, Git, and
tmux available in the user's login environment. The current app build targets
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
`build/Build/Products/Release/Chauffeur.app`. `make install` builds that Release,
quits any copy running from `/Applications/Chauffeur.app`, replaces it, verifies the
installed signature, and relaunches it (set `INSTALL_DIR` to install elsewhere).
`make open` opens the generated Xcode project, `make test` runs Swift package tests,
and `make test-ui` runs native UI tests.

## Debug and Release side by side

Debug builds use `Chauffeur Debug.app`, the `.debug` bundle-ID suffix, the
`dev.chauffeur.debug.runtime` service, and `~/Library/Application Support/Chauffeur Debug`.
Release keeps `Chauffeur.app`, `dev.chauffeur.runtime`, and the existing
`~/Library/Application Support/Chauffeur` store. Notifications, logs, URL schemes,
preferences, and installed terminal commands are also separate (`chauffeur-debug`
versus `chauffeur`), as are managed worktree checkouts (`~/.chauffeur-debug/worktrees`
versus `~/.chauffeur/worktrees`).

Startup refreshes service registration after the app moves or its runtime changes.
The app verifies the connected runtime's build, executable location/hash, and data
directory before accepting its state. Runtime settings show the verified helper
path. Explicit `CHAUFFEUR_SOCKET` connections bypass managed-service verification
and are labeled as custom connections.

## Signing

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
resolved identity for the app and every embedded helper. Local builds are not
notarized or published. Tagged releases are notarized by GitHub Actions; see
[release and notarization setup](notarization.md).

The build explicitly allows the pinned SwiftTerm build plugin, which generates
Swift version metadata from that checkout's Git revision. Its plugin and generator
sources were inspected before enabling this per-command build flag. Dependencies
are pinned in `Package.resolved` and `project.yml`.

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
[coordination skill guide](coordination-skill.md) for scope and installation
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
shared diagnostics. See [V3](decisions/V3-mcp-and-status.md) for verified scope.

Both supplied Claude profiles use the same account; the different-account Claude
check was deferred by the user. Full coordination/tool acceptance remains in V2.

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

Structured runtime logs rotate within a 2 MiB budget. See
[diagnostics and redaction](diagnostics.md) for included fields, path privacy,
storage locations, and limits.

Packaged builds launch the signed Chauffeur Sessions helper on demand. It owns
new tmux servers independently of the UI and runtime; the runtime also discovers
legacy servers. A runtime restart reconciles recorded pane/process identities;
missing ownership becomes Interrupted. Bare `.build` runtimes retain the direct,
single-server backend for development. See [privacy prompts](privacy-prompts.md)
for helper lifetimes, versioned caches, and installed Release acceptance.

Older manual prototypes that address `runtime/tmux.sock` directly assume the
single-server backend. Before running those against a packaged app, adapt their
routing and cleanup to `runtime/session-owners/*/manifest.json`; otherwise their
cleanup can leave helper-owned fixture sessions behind. Use
`Prototypes/session_owner_acceptance.py` for the packaged lifetime/privacy check. Metadata files
are human-readable JSON. External changes reload independently of the UI, and
stale saves report a conflict with the affected path.
