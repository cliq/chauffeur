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

The installed command points to `Contents/MacOS/chauffeur-launcher` inside the
app. The distinct filename is required: on a case-insensitive volume, embedding
`chauffeur` alongside the app's `Chauffeur` executable overwrites the GUI. The
embedding script rejects a target that resolves to the GUI executable.

- `FolderLauncherTests`: strict literal URLs, closest ancestors, shared folders,
  aliases, worktrees, idempotent installation and unrelated-command preservation.
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

## Remaining installation checks

The actual `/usr/local/bin/` installation still needs administrator authentication
on the development Mac. Reinstallation currently updates a link to an existing
Chauffeur app, but repair of a link whose old app has been moved/deleted remains
to be implemented and verified.
