<p align="center">
  <img src="docs/images/icon.png" alt="Chauffeur" width="128" height="128">
</p>

<h1 align="center">Chauffeur</h1>

<p align="center">
  Run Codex and Claude Code in a native macOS app.<br>
  Keep projects, CLI profiles, and worktrees organized while your agents work.
</p>

<p align="center">
  <img src="docs/images/hero-dark.png" alt="Chauffeur in dark mode, with repositories and worktrees in the sidebar and a Claude Code session showing a diff" width="900">
</p>

Chauffeur is for working across several repositories or clients with Codex and
Claude Code. Each project gets its own window, and each agent launches with the
CLI profile you choose. The CLIs run in embedded terminals with their usual
prompts, tools, and approvals.

- **Separate profiles for each client.** Save agent presets with their own
  `CODEX_HOME` or `CLAUDE_CONFIG_DIR`, then organize them into teams.
- **A window for each project.** Keep related repositories and sessions together,
  or put projects on separate macOS Spaces.
- **Worktrees from the sidebar.** Create a worktree and start an agent in one step.
  Run multiple sessions on a checkout, open a shell, and remove worktrees when
  you're done.
- **Sessions keep running after you quit.** A background service keeps agents
  running when you close a window or quit Chauffeur. Reopen the app to reconnect.
- **Session status and notifications.** See when an agent finishes a turn or needs
  input, where supported by the CLI. Open active projects from the menu bar.
- **Searchable terminal history.** Press ⌘F to search saved output, including
  sessions that have ended.

## Build and run

You'll need:

- macOS 15 or newer on Apple Silicon
- Git and tmux available in your login shell
- Codex and/or Claude Code installed and signed in
- Xcode 26.3 (Swift 6.2) and XcodeGen

To build from source, copy the local signing configuration and set
`DEVELOPMENT_TEAM` in it:

```sh
cp Configuration/LocalSigning.xcconfig.example Configuration/LocalSigning.xcconfig
```

Then build and open the app:

```sh
make build
open 'build/Build/Products/Debug/Chauffeur Debug.app'
```

For an optimized build, run `make release` and open
`build/Build/Products/Release/Chauffeur.app`. Debug and Release can run side by
side with separate settings and sessions.

See [building and verifying](docs/building.md) for signing options and tests.
For signed, notarized GitHub releases, see [release setup](docs/notarization.md).
If macOS asks you to allow the background service, follow the link to Login Items
& Extensions in the app. See [service recovery](docs/service-recovery.md) if it
won't start.

## Set up your first project

1. In **Settings → Agent Presets**, add a team, such as *Personal* or a client
   name. Add a preset for each agent you want to use, choosing its executable and
   an existing CLI configuration directory. Set up profiles and sign in through
   the CLI first.
2. Create a project and choose its team. Select a parent folder to discover
   repositories, or add repository folders individually.
3. Open the project and start a session. Choose a group, an agent preset, and an
   existing checkout or a new worktree. Add any other repositories the agent
   needs access to.

Select a checkout in the sidebar to switch between its sessions or start another
one. **Session Details** shows launch information and controls for stopping a
session or resuming its conversation.

Closing a window or quitting the app leaves sessions running. To end one, use
**Stop Session**. **Resume Conversation** starts a new execution using the saved
conversation ID and original preset.

## Agent coordination

Chauffeur includes an experimental MCP server for messages and delegation between
sessions in a project group. Codex-to-Claude messaging and delegation are still
being completed as part of [V2](docs/v2-plan.md).

The optional [coordination skill](docs/coordination-skill.md) teaches agents how
to use these tools. Install it from **Settings → Agent Presets → Chauffeur
Skill…**. It applies to all sessions using that CLI profile, including those
started outside Chauffeur.

Coordination and status reporting depend on the CLI version. Unsupported versions
require an explicit basic-terminal launch, with coordination and status features
unavailable. See [compatibility](docs/compatibility.md) for tested versions and
known limits. Full release workload testing is also pending.

## Documentation

The [app manual](docs/manual.html) covers the screens, workflows, and keyboard
shortcuts. Open it locally in a browser.
