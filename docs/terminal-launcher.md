# Open a project from Terminal

In **Settings → Runtime → Terminal Command**, choose **Install Terminal Command…**.
The command is installed at `/usr/local/bin/chauffeur`. macOS requests administrator
authentication when that directory is not writable by the current user.

```sh
chauffeur                       # use the current folder
chauffeur ~/Projects/example    # use a selected folder
chauffeur "./folder with spaces"
chauffeur -- ./-example
```

Chauffeur finds the closest registered repository or worktree containing the
folder and opens its project window, selecting that repository in the sidebar.
Worktrees observed through Git inventory are included. If multiple projects
share the closest matching folder, a project chooser appears. An unregistered
folder produces an explanation in the app. Opening a project does not launch an
agent. On a cold launch, only the requested project opens; repeated commands
reuse an existing window. Other windows already open remain open.

## Packaging and verification

The installed command is a short shell script that executes
`Contents/MacOS/chauffeur-launcher` inside the app and passes all arguments
unchanged. Its ownership marker lets Chauffeur replace its own command after
the app moves, even if the old app no longer exists. Reinstall it from Settings
in the new location. Existing unrelated commands are preserved; an earlier
symlink installation can be upgraded while its original app is still present.

The distinct embedded filename is required: on a case-insensitive volume, embedding
`chauffeur` alongside the app's `Chauffeur` executable overwrites the GUI. The
embedding script rejects a target that resolves to the GUI executable.

- `FolderLauncherTests`: strict literal URLs, closest ancestors, shared folders,
  aliases, worktrees, idempotent installation, unrelated-command preservation,
  actual execution with literal arguments, repair after moving the app, and
  upgrade from an existing app link.
- `Prototypes/folder_launcher_smoke.py`: actual Launch Services cold/warm routing,
  nested/relative/Unicode/symlink paths, no duplicate windows, ambiguous project
  choice, invalid paths, and cold relaunch. It also stops the isolated runtime,
  changes a window layout, and verifies the queued change saves after recovery.
- `Prototypes/release_startup_smoke.py`: signs an isolated copy of the built
  Release app, starts it through Launch Services, checks a real visible app
  window, and captures that window for inspection. Signature verification alone
  does not establish that the GUI executable is correct.

All native fixtures use isolated runtime stores, no provider accounts, and no
agent sessions. Results are under `.build/folder-launcher-artifacts/` and
`.build/release-startup-artifacts/`.

## Native installation evidence

On 2026-09-16, the user authorized installation through the signed Release app's
native macOS administrator prompt. `/usr/local/bin/chauffeur` is a root-owned
executable with mode 0755 and points to that Release's `chauffeur-launcher`.
The installed command's help and relative-folder invocation both pass; running
it from a registered repository opens Signos while preserving existing session,
message and preset records and the same runtime. Private evidence:
`.local/launcher-native/summary.json`. Relocation repair and literal forwarding
also pass in private writable destinations.
