# Chauffeur — Worktree-centred project window

Status: implemented on 2026-09-16; see [V6 decision record](decisions/V6-worktree-navigation.md).

Plan agreed with the user on 2026-09-16. Replaces the session tab strip in the
project window with a worktree-driven layout while keeping the flat session list
as a second sidebar mode. Nothing here changes coordination, groups, presets, or
the runtime's session lifecycle except for the new shell session kind in Phase 4.

## Decisions from the interview

| Topic | Decision |
| --- | --- |
| Sidebar | Segmented control at the top: **Repositories** / **Sessions**. Repositories shows the repo → worktree tree. Sessions shows the flat list with the group picker and search, as today. |
| Tabs and split | Removed in both modes. The main area shows one terminal for the selected session. Split terminal and its menu command go away. |
| Main area | Header with worktree path and branch, then a **session strip** for the selected worktree, then the terminal or an empty state. |
| Session strip cards | Three lines: title, `preset · group`, state with attention colouring. Close on a card hides nothing; live cards get **Stop**, finished cards are grouped. |
| Which sessions | Every stored session for the worktree. Live ones first; finished ones (exited, failed, interrupted) collapsed behind a **Finished** disclosure at the end of the strip. |
| Empty state | "No sessions on this worktree" with two actions: **Launch Agent…** and **Open Shell**. The same two actions are available when sessions exist, as toolbar and context-menu items. |
| Main checkout | Each repository gets a `main` row under it that behaves like a worktree row pointed at the repository folder. Selecting the repository row itself shows a repo overview (all worktrees, their sessions, attention counts) with Launch Agent / Open Shell defaulting to the main checkout. |
| Shell | A service-backed session, launched and persisted like an agent session with a `shell` kind. Survives window close, listed on the worktree strip, stoppable. No coordination, no capability probing. |
| Attention | Orange badge with a count on the worktree row, summed on the repository row (also when collapsed). ⌘⇧A cycles attention sessions in either mode and selects the right worktree. |
| Persistence | Window state remembers sidebar mode, selected folder, selected worktree path, and selected session. Group selection is kept for Sessions mode. |
| Shared state | One selected session and one selected worktree regardless of mode. Selecting a session in Sessions mode also selects its worktree, so switching modes lands in the right place. |

## Current state (what the change touches)

- `Sources/ChauffeurApp/ProjectWindow.swift` owns everything: `ProjectLayout`
  (tabs, split, selected folder/worktree, search), the sidebar with the group
  picker, search field, repository tree, `Needs Attention` and `Sessions`
  sections, the header, the tab strip, the terminal area and its empty state,
  the `chauffeurCommand` handler, and session/project route consumption.
- `WindowState` in `Sources/ChauffeurCore/Records.swift` stores `tabs`,
  `splitSessionID`, `selectedSessionID`, `selectedGroupID`, and validates that
  the selected and split sessions are in `tabs`.
- The sidebar worktree row today only highlights the row and opens the Manage
  Worktrees sheet. The main area is driven solely by `selectedSessionID`.
- `ChauffeurApp.swift` defines menu commands `new-session`, `split`,
  `search-sessions`, `find`, `next`, `previous`, `attention`.
- `NativeProbe.swift` and several `Prototypes/*_smoke.py` scripts drive the
  window through `state.tabs` and `splitSessionID`.
- `Tests/ChauffeurAppUITests/ProjectWindowsTests.swift` seeds `tabs` and a
  split session into saved window records.
- Launch pipeline (`RuntimeCoordinator` ~line 470–565) requires a preset with a
  `CLIKind` of `codex` or `claude`, probes `--version`/`--help`, applies the
  shared-checkout claim, and spawns via `TmuxHost.spawn`.

## Phase 1 — Data model and state

Goal: window state that can express the new layout, with old records loading.

1. `WindowState` (`Records.swift`)
   - Add `sidebarMode: SidebarMode = .repositories` (`enum SidebarMode: String, Codable { case repositories, sessions }`).
   - Add `selectedFolderID: UUID?` and `selectedWorktreePath: String?` so the
     worktree selection survives relaunch. `nil` path with a folder means the
     main checkout.
   - Keep `selectedSessionID` and `selectedGroupID`.
   - Keep `tabs` and `splitSessionID` as optional decode-only fields for one
     release so saved records still decode; stop writing them. Relax
     `validate()` to drop the `tabs` containment checks.
   - No `WireProtocol.major` bump: all changes are additive and optional.
2. `ProjectLayout` (`ProjectWindow.swift`)
   - Remove `controllers` bookkeeping for tabs, `select`/`closeTab`/`toggleSplit`.
   - Add `selectWorktree(folderID:path:)` and `selectSession(_:)`. Selecting a
     session sets the worktree from the session's `worktreeID` or working
     directory (existing `revealSessionCheckout` logic).
   - `synchronizeTerminals` attaches only the selected session's controller and
     detaches every other one. Keep a controller cache keyed by session so
     switching between sessions on a worktree keeps scrollback.
   - Move `selectedFolderID` / `selectedWorktreePath` from published layout
     properties into `state` so they persist.
3. Add a pure helper `WorktreeSessions` (new file in `ChauffeurApp` or
   `ChauffeurCore`) that groups a project's sessions by checkout:
   `sessions(for folder:, worktreePath:)` matches `session.worktreeID` first,
   then falls back to `launch.workingDirectory == path`. Main checkout matches
   `worktreeID == nil && workingDirectory == folder.canonicalPath`. Unit-test it
   in `ChauffeurCoreTests` if placed in Core.

## Phase 2 — Sidebar

Goal: two sidebar modes sharing one selection.

1. Replace the group picker + search header with a `Picker(.segmented)` bound to
   `state.sidebarMode`, accessibility identifier `sidebar.mode`.
2. **Repositories mode**
   - Repository row: label plus attention badge (sum of child rows). Tap selects
     the folder with `selectedWorktreePath = nil` and shows the repo overview.
     Context menu keeps New Session Here, New Worktree & Session, Manage
     Worktrees, Relink / Edit Folder, Reveal in Finder, and gains **Open Shell**.
   - New first child row `main` (branch of `folder.canonicalPath`, identifier
     `repository.main.<folderID>`). Behaves exactly like a worktree row with the
     path set to the folder's canonical path. Branch name comes from the
     repository inventory entry whose path equals the folder path; fall back to
     "main checkout" when the inventory is unavailable.
   - Worktree rows: as today plus attention badge and a live-session count.
     Tap selects the worktree and no longer opens the Manage Worktrees sheet
     (that stays in the context menu and the toolbar menu). Context menu gains
     **Launch Agent…** and **Open Shell**.
   - Keep `New Worktree & Session…` and `Add Folder…` buttons and `No worktrees`
     placeholder (now shown only when there is nothing besides `main`).
   - Remove the `Needs Attention` and `Sessions` sections from this mode.
3. **Sessions mode**
   - Group picker, search field, `Needs Attention` and `Sessions` sections move
     here unchanged. `sessionRow` calls `layout.selectSession`, which also sets
     the worktree. Remove the `Open Terminal` context item (redundant) and keep
     Session Details / Stop.
4. `search-sessions` command switches to Sessions mode before focusing the
   field. `sidebarReveal` scrolling works in Repositories mode only; guard it.
5. Footer text becomes "Closing a window keeps agents running."

## Phase 3 — Main area

Goal: worktree-driven detail column with the session strip.

1. **Header**: show the selected checkout's path and branch even when no
   session is selected. Right side hosts **Launch Agent…** and **Open Shell**
   buttons (disabled offline, archived, or when the checkout is unavailable).
2. **Session strip** (`SessionStrip` view, replaces `tabs`)
   - Horizontal scroll of cards for `WorktreeSessions.sessions(for:)`. Live
     sessions sorted by `createdAt`, selected card highlighted with the accent
     background used by today's tabs.
   - Card content: title; `launch.preset.name · group name`; `state.label` plus
     pending message count, orange when `needsAttention`. Context menu: Session
     Details, Stop Session… (live only), Reveal in Finder.
   - Trailing **Finished (n)** disclosure toggles visibility of non-live
     sessions; they render as dimmed cards and open read-only history when
     selected (existing `TerminalPane` snapshot behaviour).
   - Strip is hidden entirely when the worktree has no sessions.
3. **Terminal area**
   - Single `TerminalPane` for the selected session. Remove `HSplitView` and
     the split `ForEach`.
   - Empty state when the selected worktree has no sessions:
     `ContentUnavailableView("No sessions on this worktree")` with Launch
     Agent… (borderedProminent) and Open Shell.
   - Empty state when nothing is selected: "Choose a repository or worktree".
4. **Repo overview** (selected folder, `selectedWorktreePath == nil`, not on
   the `main` row): a list of the repository's checkouts (main first), each with
   branch, live count, attention count, and a button to open it. Launch Agent…
   / Open Shell here target the main checkout.
5. **Launch sheet**: `SessionLaunchView` already accepts `initialFolderID`;
   add `initialWorktreePath` (or worktree ID) so Launch Agent… preselects the
   checkout. Completion calls `layout.selectSession`.
6. **Toolbar**: remove Split Terminal. Keep New Session, Session Details, and
   the actions menu.
7. **Commands**: delete `split` from `ChauffeurApp.swift` and the handler.
   `next`/`previous` cycle sessions within the selected worktree's strip.
   `attention` cycles all attention sessions in the project and selects each
   one's worktree.
8. **Routes**: `consumeSessionRoute` calls `selectSession` and leaves
   `sidebarMode` unchanged. Drop the `selectedGroupID = session.groupID`
   assignment; in Sessions mode, if the picker would hide the routed session,
   reset the picker to All Groups instead.
9. **Persistence**: `restore()` loads mode, folder, worktree path, and session,
   validates the session still belongs to the project, and falls back to the
   session's checkout if the stored worktree is gone.

## Phase 4 — Shell sessions

Goal: "Open Shell" creates a service-backed shell in the checkout.

1. `CLIKind` gains `case shell`. `AgentPreset.validate` and
   `LaunchPolicy.validateArguments` accept it (no argument policy).
2. Launch path in `RuntimeCoordinator`:
   - `LaunchRequest` gains `kind: LaunchKind = .agent` (`agent | shell`). A
     shell request ignores `presetID` and `coordinationEnabled`, and uses the
     user's login shell (`SHELL` from the base environment, default `/bin/zsh`)
     with `-l`.
   - Build a synthetic `AgentPreset(kind: .shell, executable: shell,
     configurationDirectory: workingDirectory)` for the `LaunchSnapshot` so the
     record shape is unchanged. Title defaults to `Shell · <branch or folder>`.
   - Skip `CLIAdapter.capabilities`, integration directory, MCP config, and the
     `shared_checkout` claim for shells (a shell must not force
     `allowSharedCheckout` on agents, and agents must not block shells). Still
     set `gitWorktreeIdentities`/`checkoutIdentities` so recovery works.
   - `CLIAdapter.arguments` returns `preset.arguments` for `.shell`.
   - Resume is unsupported: `resume` throws `resume_unavailable` for shells.
   - Status: shells stay `activityUnknown` while live; exit maps to `exited`.
     Attention never fires for shells (no hooks).
3. Store: `rememberPreset` is skipped for shells.
4. App: `AppModel` gains `openShell(projectID:folderID:worktreeID:path:)`
   issuing the launch request with `kind: .shell` and the folder's default
   group. Strip cards show `Shell` in place of the preset name. Session Details
   hides preset/integration rows for shells.
5. Prototype `Prototypes/fake_cli.py` fixtures are unaffected; UI tests can
   launch a real `/bin/zsh` shell since it needs no fake CLI.

## Phase 5 — Probes, smoke scripts, tests, docs

1. `NativeProbe.swift`: replace `state.tabs`/`splitSessionID` assertions with
   `selectedSessionID`, `selectedFolderID`, `selectedWorktreePath`. Drop the
   "restored split terminals" wait. `QuickSessionProbe` already reports
   `selectedWorktree`; add `selectedSession` and `sidebarMode`.
2. `ProjectWindowsTests`: seed `selectedSessionID` plus folder instead of
   `tabs`/split. Update the split screenshot name. Add assertions that the
   worktree row identifier exists and that selecting it shows the strip.
3. Smoke scripts (`grep -l "tabs\|split" Prototypes/*.py`) — update the ones
   that read window state: `native_window_smoke.py`, `session_controls_smoke.py`,
   `terminal_controls_smoke.py`, `quick_session_smoke.py`,
   `worktree_controls_smoke.py`, `native_attention_smoke.py`,
   `notification_native_smoke.py`, `history_rotation_smoke.py`, and the
   `real_*` scripts. Each needs the split scenario removed and the worktree
   selection scenario added.
4. New Core tests: `WorktreeSessions` grouping (worktree ID match, working
   directory fallback, main checkout), `WindowState` decoding of a legacy record
   containing `tabs` and `splitSessionID`, shell launch request validation.
5. Docs: update `docs/manual.html` window section, `docs/worktrees.md`,
   `docs/implementation-status.md`, and remove Split Terminal from the shortcut
   list. Add a decision record `docs/decisions/V6-worktree-navigation.md`
   summarising the table above.

## Suggested order and checkpoints

1. Phase 1 + Phase 5 legacy-decoding test. Build, run unit tests.
2. Phase 2 and Phase 3 together (they are one view file). Run the app on the
   iPhone-free macOS target with a project that has worktrees; verify:
   selecting worktree shows its sessions, empty state on a bare worktree, mode
   switch keeps selection, relaunch restores mode/worktree/session, ⌘⇧A jumps
   worktrees, notification route lands on the session.
3. Phase 4. Verify Open Shell from a worktree row, main row, repo overview, and
   the empty state; close and reopen the window and confirm the shell is still
   listed and attachable; Stop works; an agent can launch on the same checkout
   without the shared-checkout prompt.
4. Phase 5 remainder. Run `Tests/ChauffeurAppUITests` and the updated smoke
   scripts.

## Risks and open items

- **Session-to-worktree matching for old sessions.** Sessions launched before
  worktree records existed only have `workingDirectory`; the fallback covers
  them, but a worktree moved on disk will show its old sessions under the old
  path. Acceptable; the Sessions mode still lists them.
- **Shared-checkout semantics with shells.** Excluding shells from the claim is
  a product choice; if a user edits files in the shell while an agent runs, no
  warning is shown. Documented in the decision record.
- **Shell as a `CLIKind`.** Reusing `AgentPreset` for shells keeps the record
  shape but means the Presets UI must filter out `.shell` (never stored in a
  preset set). Alternative is a separate `SessionKind` on `Session`; chosen the
  preset route for smaller blast radius.
- **`WireProtocol.major`.** Only bump if the CLI (`chauffeurctl`) or runtime
  rejects unknown `LaunchRequest.kind`. Check `LaunchRequest` decoding is
  lenient before shipping.
- **Repo overview scope.** Kept deliberately small (list + two actions). It can
  grow into per-worktree stats later without affecting the rest of the plan.
