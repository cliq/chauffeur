# Chauffeur — MVP implementation plan

- Date: 2026-09-15
- Status: Proposed. Technical decisions below are starting positions to be confirmed or replaced by the Stage 0 validation gates.
- Companions: [Project overview](overview.md), [MVP PRD](mvp-prd.md)
- Development machine at time of writing: macOS 26.6.2, Swift 6.2.4, XcodeGen, tmux available; Codex `0.154.0`, Claude Code `2.1.272`

This plan turns the PRD's requirements (F1–F7), validation gates (V1–V5), and delivery stages (0–4) into concrete technical decisions, a repository layout, and ordered work items. Requirement references such as **F4.3** point to the PRD.

## 1. Guiding constraints

Four PRD commitments drive every decision below:

1. **Agents outlive the UI** (F4.3, F4.6). Process ownership must live in a per-user background runtime, never in the app process.
2. **Coherent terminal reattachment** (F4.4). Surviving processes are not enough; the screen must be reconstructed on attach.
3. **Profile selection is per child process** (F2.2, F2.3). `CODEX_HOME` and `CLAUDE_CONFIG_DIR` are set on the spawned process only, and a bad path fails the launch.
4. **One MCP server, server-enforced groups** (F7). Group membership is resolved from a per-session credential, never from anything the agent supplies.

## 2. Technical decisions

| Area | Decision | Rationale and fallback |
| --- | --- | --- |
| Language | Swift 6 for the app, runtime, core library, and CLI helper. | One toolchain and one shared model/protocol package. Fallback for the MCP layer only: a small TypeScript sidecar using the official MCP SDK if the Swift HTTP implementation fails V3. |
| App shell | SwiftUI `WindowGroup(for: Project.ID)` with AppKit hosting where needed. | `openWindow(value:)` gives one window per project and focuses an existing window for the same value (F3.1). SwiftUI window restoration covers F3.4. |
| Terminal rendering | SwiftTerm `TerminalView` in the app; headless SwiftTerm `Terminal` per session in the runtime. | The runtime keeps an authoritative emulated screen while no view is attached (F4.3). On attach, the runtime serializes the screen (cells, attributes, cursor, modes, bounded scrollback) as an ANSI redraw, then streams live bytes. Fallback if V1 shows fidelity problems: tmux control mode (`tmux -CC`) as the PTY owner behind the same runtime API. |
| PTY and processes | `posix_spawn` + `openpty`/`forkpty` equivalents in the runtime; each child in its own process group and session (`setsid`). | Keeps signals scoped to one agent (F4.5). A runtime crash still closes the PTY master and hangs up the child; this is the accepted **Interrupted** path (F4.8). A per-session PTY holder process is a later hardening option, not MVP. |
| Background runtime | `ChauffeurRuntime` executable registered as a launchd LaunchAgent through `SMAppService.agent(plistName:)`, `KeepAlive` true, single instance guarded by a lock file. | Survives UI quit and crash; launchd restarts it after failure so the UI can report **Interrupted** sessions (F4.8, §6). |
| UI ↔ runtime IPC | Unix domain socket at `~/Library/Application Support/Chauffeur/runtime.sock`, length-prefixed JSON frames, `Codable` messages defined in `ChauffeurCore`. | Debuggable from the command line, easy to test, streaming friendly. XPC/Mach services were rejected to keep protocol inspection simple; the same protocol serves the `chauffeurctl` helper. |
| Persistence | Human-readable JSON files under `~/Library/Application Support/Chauffeur/`, one directory per preset set and per project (layout in §2.1). Atomic write-then-rename, the runtime as the single writer, file watching for external edits. | Projects can be inspected, backed up, copied, or deleted with Finder or a shell, and there is no schema to migrate. Only the runtime-internal mailbox and delegation ledger uses a small SQLite file, because message acceptance and launch retries need transactions (§6); it holds no user-managed data and can be replaced by append-only JSONL if a database-free layout is preferred. |
| MCP server | Hummingbird 2 HTTP server on `127.0.0.1` with an ephemeral or configured port; hand-written JSON-RPC handling for the Streamable HTTP subset (`initialize`, `ping`, `tools/list`, `tools/call`, JSON responses; SSE stream deferred unless V3 requires it). | Only five tools are needed (F7). Owning the protocol layer avoids dependency risk and keeps auth in one place. Bearer token per session in the `Authorization` header; `Origin` check; unauthenticated or unknown tokens return an error and never a default group. |
| Codex integration | Launch-scoped `-c` overrides: `mcp_servers.chauffeur.url`, `mcp_servers.chauffeur.bearer_token_env_var`, `notify`, `-C <dir>`. Hooks only if V3 shows they can be trusted without editing the user's directory. | No writes into `CODEX_HOME`. Codex requires persisted hook trust for hooks; the `notify` hook (`agent-turn-complete`) is the primary turn signal candidate. |
| Claude Code integration | `--mcp-config <per-launch file>` with `${CHAUFFEUR_SESSION_TOKEN}` header expansion, `--settings <per-launch file>` for namespaced hooks, `--add-dir` for additional repositories, `--session-id <uuid>` to pre-assign the conversation ID, `--resume <uuid>` for resume. | All launch-scoped; existing MCP servers and settings stay intact (F7 preset integration). `--strict-mcp-config` is never used. |
| Status signals | Hook/notify commands invoke `chauffeurctl event --session $CHAUFFEUR_SESSION_ID <event>` which reports over the Unix socket. | Semantic status comes only from documented signals (F6). Missing signals produce **Activity unknown**, never inferred completion. |
| Skill | A versioned `chauffeur` skill directory (`SKILL.md`) shipped in the app bundle. | Loading route is decided in V3 per CLI; MCP tool descriptions must stand alone (F7). |
| Project generation | XcodeGen `project.yml` for the app target; Swift Package for `ChauffeurCore`, `ChauffeurRuntime`, `chauffeurctl`, and tests. | Matches the existing local tooling; xcconfig-based signing for the app and embedded runtime binary. |

### 2.1 On-disk layout

```
~/Library/Application Support/Chauffeur/
  preset-sets/<set-slug>/preset-set.json          name, default preset, revision
  preset-sets/<set-slug>/presets/<preset-slug>.json  CLI kind, executable, config directory, arguments
  projects/<project-slug>/project.json            name, preset-set reference, discovery folder, folders, groups, archive flag, timestamps
  projects/<project-slug>/sessions/<session-id>.json  session record and launch snapshot
  projects/<project-slug>/worktrees/<worktree-id>.json  worktree record (branch, base commit, path, ownership)
  projects/<project-slug>/window-state.json       frame, tabs, selection, split, sidebar
  worktrees/<repo-id>/<branch-slug>/              managed Git checkouts
  runtime/runtime.sock, runtime.lock              IPC socket and single-instance guard
  runtime/ledger.sqlite                           mailbox and delegation ledger (runtime-internal)
  runtime/snapshots/<session-id>/                 terminal screen and bounded scrollback
~/Library/Logs/Chauffeur/                         structured logs
```

Rules for this layout:

- **Identity**: every record carries a stable UUID inside the file. Directory names are human-readable slugs assigned at creation, with a numeric suffix on collision. Renaming a project changes the name in the file, not the directory, so references never break.
- **References**: a project points to a preset set by ID, and the runtime resolves it by scanning `preset-sets/`. A missing set is shown as unresolved, not silently replaced.
- **Single writer**: the runtime performs all writes so concurrent project windows cannot race. The app sends commands over the socket and receives change notifications.
- **Atomicity**: each file is written to a temporary sibling and renamed into place. A record that fails JSON validation is reported in the UI with its path and skipped, never deleted or rewritten.
- **External edits**: the runtime watches `preset-sets/` and `projects/` and reloads changed files. Deleting a project directory archives its sessions in memory until the runtime restarts; it does not terminate live agents.
- **Opening a project**: the project list is the contents of `projects/`, sorted by the last-opened timestamp in each `project.json`. Archived projects carry a flag and stay in place.

### Environment handling for launches (F2)

The runtime builds each child environment explicitly: it starts from a filtered copy of the user's login environment, removes provider and CLI variables that could redirect a profile (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, and a maintained deny list), then sets the preset's configuration directory, `CHAUFFEUR_SESSION_ID`, `CHAUFFEUR_SESSION_TOKEN`, and `TERM`. Preflight checks the executable, directory readability, and that the resolved configuration directory equals the preset's canonical path; any failure aborts before spawn.

## 3. Repository layout

```
chauffeur-ade/
  docs/                         overview, PRD, this plan, decisions/, compatibility.md
  project.yml                   XcodeGen definition for ChauffeurApp
  Package.swift                 ChauffeurCore, ChauffeurRuntime, chauffeurctl, tests
  Sources/
    ChauffeurCore/              records, IPC protocol, MCP tool schemas, validation
    ChauffeurRuntime/           launchd entry point, PTY manager, snapshot, DB, MCP server, IPC server
    ChauffeurCtl/               hook/notify event reporter and diagnostics CLI
    ChauffeurApp/               SwiftUI/AppKit app: windows, sidebar, terminal hosting, settings
  Resources/
    skills/chauffeur/SKILL.md   supporting skill
    launchd/                    LaunchAgent plist template
  Prototypes/                   Stage 0 spikes, deleted or promoted after each gate
  Tests/
    ChauffeurCoreTests/
    ChauffeurRuntimeTests/      integration tests against a fake TUI CLI script
```

Each Stage 0 gate records its outcome in `docs/decisions/Vn-<topic>.md`. `docs/compatibility.md` records tested CLI versions and detected capabilities (§6).

## 4. Stage 0 — Validate foundations

Each gate is a throwaway spike in `Prototypes/` with a written decision. No dependent feature starts before its gate passes or a documented resolution exists.

| Gate | Spike | Pass evidence | Failure path |
| --- | --- | --- | --- |
| V1 Terminal continuity | Runtime process owns a PTY running each CLI; headless SwiftTerm mirrors output; a separate app attaches, receives a serialized screen, resizes, types, detaches, and the runtime is killed and restarted only for the UI. | Both CLIs render full-screen UIs correctly after reattach; resize propagates; scrollback bounded to a configured limit; no bytes lost while detached. | Swap PTY ownership to tmux control mode behind the same runtime API. |
| V2 Configuration selection | Spawn Codex with two `CODEX_HOME` values and Claude Code with two `CLAUDE_CONFIG_DIR` values concurrently using the filtered environment. | `codex doctor` and Claude Code diagnostics report the intended directory and account per process; an invalid path aborts before spawn; inherited API-key variables do not change the account. | Extend the environment deny list or add a wrapper check; record any variable that cannot be neutralized. |
| V3 MCP integration and status | Minimal Hummingbird server with bearer auth and one `discover` tool; launch both CLIs with launch-scoped MCP configuration; wire `notify`/hooks to `chauffeurctl`. | Both CLIs list and call the tool with per-session tokens while sharing one preset directory; pre-existing MCP servers still load; turn-finished and needs-attention signals arrive with the session ID; skill loading route per CLI is documented. | If JSON-only responses are rejected, add SSE. If hooks need persisted trust, use `notify` only for Codex and document reduced status. |
| V4 Groups and delivery | Two groups in one project plus a group in another project on the same server; queued messages, bounded inbox wait, delegation launching a child in the other CLI. | Guessed IDs across groups fail; queued messages survive runtime restart; busy recipient keeps its queue; no terminal input is ever injected; child inherits group, preset, and worktree. | Redesign credential/group resolution before Stage 3. |
| V5 macOS lifetime | LaunchAgent registration via `SMAppService`, four SwiftUI project windows on separate Spaces, notification opening the right window with the UI relaunched. | Runtime stays alive with no UI; `openWindow(value:)` focuses rather than duplicates; window frames restore. | Fall back to a login item plus manual restart guidance; record Spaces limitations. |

Exit: five decision documents and a chosen terminal-ownership approach.

## 5. Stage 1 — Projects and profiles

Goal: four project windows launching real terminals with the intended presets (PRD stage 1 exit).

1. **Core records and file store** — `Codable` records and the directory layout from §2.1 for preset sets, presets, projects, folders, groups, sessions, and window state; atomic writes, slug assignment, validation with path-bearing errors, and a file watcher. Canonical-path helper and duplicate detection (F1.3). Unit tests for validation rules (empty set cannot launch, F1.1) and for reloading a hand-edited or corrupted file.
2. **Runtime skeleton** — launchd registration, lock file, Unix socket server, `hello`/`version` handshake, structured logging to `~/Library/Logs/Chauffeur/`. `chauffeurctl status` reports runtime health (§6).
3. **Preset management UI** — preset sets, presets with CLI kind, executable discovery (`PATH` lookup plus explicit selection), configuration directory picker, launch arguments as an argument list, shared-directory indicator (F2.1, F2.7).
4. **Project creation** — name, preset set, **Choose parent folder** with cancellable discovery (skips `.git` internals, follows no symlink loops, recognizes `.git` files), **Start empty**, add folder later, relink missing folders (F1.2–F1.4).
5. **Groups** — Default group per project; create, rename, archive, reopen (F1.7).
6. **Welcome window** — a single-instance window modeled on Xcode's: on the left the app icon, version, and **Create New Project…**; on the right the projects from `projects/`, sorted by last opened, each showing name, preset set, the folder path when only one is registered, and live counts of running sessions and sessions needing attention from the runtime. Shown at launch when no project window is restored, available from the Window menu and a shortcut, hidden when a project window opens. Double-click or Return opens the project and focuses an existing window. Archived projects behind a toggle; a runtime health line at the bottom that names a stopped background service. Right-click offers Rename, Archive, and Reveal in Finder for the project directory (F3.2).
7. **Project windows** — `WindowGroup(for:)`, header with project and preset set, sidebar with folders and sessions, group filter, empty terminal area; window state persistence (F3.1, F3.3–F3.5).
8. **Basic launch** — session creation sheet (group, preset, folder, optional initial task), preflight, spawn with the filtered environment, attach SwiftTerm view, interrupt and stop actions with force-stop fallback (F2.2–F2.6, F4.2, F4.5).
9. **Session details** — preset name, effective configuration path, working directory, launch snapshot (F2.5).

Exit check: the F1 and F2 acceptance scenarios pass, including the invalid-path failure and the shared-preset edit affecting only new launches.

## 6. Stage 2 — Durable daily workflow

Goal: quit and reopen without losing sessions; worktrees; attention (PRD stage 2 exit).

1. **Headless screen and snapshots** — per-session headless emulator, attach protocol (snapshot then stream), resize handling, single active attachment with ownership tokens (F4.4, F4.10). Persist bounded scrollback to disk with configurable limits and a documented cleanup policy (§6).
2. **Reconnect flows** — UI startup reconciles runtime sessions; distinguishes live PTY reattach from **Interrupted** after runtime restart; explicit **Resume conversation** action using recorded native IDs (`claude --resume`, `codex resume <id>`) that never uses "resume latest" (F4.7, F4.8).
3. **Quit semantics** — **Quit Chauffeur** detaches; **Stop all sessions and quit** enumerates targets; window close never signals processes (F3.7, F4.6).
4. **Tabs and split** — terminal tabs per window, two-pane split, keyboard commands for new session, switch, split, terminal search, next attention item; verify that CLI control keys pass through (F3.6).
5. **Worktrees** — create with base ref and branch under `~/Library/Application Support/Chauffeur/worktrees/<repo-id>/<branch-slug>`, collision-safe naming, recorded base commit; list via `git worktree list --porcelain`; reconcile external changes; removal only when app-managed, clean, and without live sessions; unregister external worktrees (F5.1–F5.4, F5.8).
6. **Multi-repository access** — additional paths shown at launch, passed via `--add-dir` for Claude Code and the equivalent Codex mechanism verified in V3; no implicit main-checkout when the primary is a worktree (F5.6, F5.7). Shared-checkout warning listing existing sessions (F5.5).
7. **Status model** — lifecycle states from the PRD table driven by process events plus `chauffeurctl event`; attention list per project; optional macOS notifications that open the right window (F6).
8. **Sleep/wake and service loss** — reconcile on wake, detect stopped runtime, show recovery actions (F4.9, §6).
9. **Appearance setting** — add a Settings choice between **System**, **Light**, and **Dark** appearance; persist the selection and apply it across app windows and terminal views.
10. **Terminal project launcher** — install a launcher in `/usr/local/bin/` that opens the Chauffeur project containing the selected folder.
11. **Quick session on a new worktree** — create a worktree and start a session from its repository in the sidebar in one flow.

Exit check: F3, F4, F5, and F6 acceptance scenarios pass for both CLIs, including force-quitting only the UI.

## 7. Stage 3 — Coordination

Goal: cross-provider delegation while the UI is closed (PRD stage 3 exit).

1. **Credentials** — per-session random token stored hashed; issued at launch, revoked on stop/remove, reissued on resume (F7 authentication).
2. **MCP server** — Streamable HTTP endpoint inside the runtime; tools `chauffeur_discover`, `chauffeur_send_message`, `chauffeur_inbox` (with bounded wait and acknowledge), `chauffeur_reply`, `chauffeur_delegate`, `chauffeur_delegation_status`, `chauffeur_report_result`. Names are provisional; every call resolves the caller's group from the token and filters all results by it (F7 capabilities).
3. **Mailboxes** — messages persisted in a transaction before acceptance; states queued, received, acknowledged, failed/cancelled; idempotency keys for retries; inbox preserved after recipient exit (F7 delivery semantics).
4. **Delegation** — child session created through the same launch path as user sessions and recorded as a session file in the parent's project; inherits project and group; default new worktree, explicit shared checkout; single-level only; configurable live-child limit defaulting to four; failed launches recorded as failed delegations (F7 delegation behavior).
5. **Wake path** — V3/V4 result decides whether an idle CLI can be woken; otherwise pending messages surface as **Needs attention** and the user prompts the recipient (F7 delivery 3).
6. **UI** — messages and delegation tree in session details, delivery state, sender and group labels (F7 delivery 6).
7. **Skill** — `SKILL.md` describing discover, inbox wait, delegate, report; installed by the route chosen in V3 with namespaced files only and a removal action.

Exit check: F7 acceptance, including cross-group probing with guessed IDs, retries without duplicate launches, and delegation with the UI closed.

## 8. Stage 4 — Personal-use release

1. Release build script producing a signed local app with the embedded runtime and `chauffeurctl`; first-run runtime registration and health check.
2. `docs/compatibility.md` with tested CLI versions, detected capabilities, and degraded-mode behavior; capability detection at launch marks unsupported coordination or status visibly (§6).
3. Retention settings UI: scrollback lines, snapshot disk budget, message history limit, cleanup that never touches native conversations or queued messages.
4. Diagnostics export: executable, version, configuration path, working directory, runtime state, recent errors; no credentials or configuration file contents.
5. Setup and recovery notes in `docs/` covering runtime restart, interrupted sessions, and worktree cleanup.
6. Run the PRD §9 end-to-end checklist, including ten concurrent sessions with recorded hardware and timings, then three workdays of daily use with a failure log.
7. **Complete app manual** — after the app work is finished, write a manual covering every feature and how to use it, and publish it through the Artifact Colab MCP.

## 9. Cross-cutting engineering rules

- **Testing**: `ChauffeurCore` gets unit tests for path canonicalization, environment filtering, validation, and group authorization. `ChauffeurRuntime` gets integration tests against a fake TUI CLI (a script that draws an alternate screen, echoes input, and emits synthetic hook events) so PTY, snapshot, and mailbox behavior are testable without provider accounts. Real-CLI scenarios are manual checklists per stage.
- **Logging**: structured logs with session IDs; a redaction layer blocks tokens, API keys, and configuration file contents.
- **Concurrency**: runtime state behind actors; one actor per session for PTY I/O; a single store actor serializes file writes and ledger access.
- **Protocol evolution**: IPC and snapshot formats carry a version; UI and runtime refuse mismatched majors and prompt for runtime restart.
- **Commits**: one stage item per branch or commit series; each gate decision committed with its prototype outcome.

## 10. Risks and open questions

| Risk | Mitigation |
| --- | --- |
| Snapshot fidelity for full-screen TUIs (mouse modes, cursor shapes, sixel or images) is worse than expected. | V1 decides early; tmux control mode fallback keeps the runtime API unchanged. |
| Codex hooks require persisted trust stored in the user's directory. | Use `notify` for turn completion; document degraded needs-attention detection for Codex until a launch-scoped route exists. |
| Claude Code `--settings` or `--mcp-config` behavior changes between versions. | Capability detection per version in `compatibility.md`; pin tested versions; keep terminal launch usable without integration. |
| Unknown Codex mechanism for additional directories. | V3 verifies; if unavailable, expose additional paths in the initial task and skill guidance. |
| Waking an idle CLI on inbox delivery may be impossible without terminal injection. | Treat as unsupported unless V4 proves a documented path; rely on bounded inbox wait and attention state. |
| Runtime crash hangs up every PTY. | Accepted for MVP with clear **Interrupted** state; per-session PTY holder as a later hardening item. |
| Hand-edited project files conflict with runtime writes. | Runtime is the single writer; external edits are reloaded on change, validation errors name the file, and a conflicting write is refused with a reload prompt instead of overwriting. |
| Streamable HTTP without SSE is rejected by a client. | Add SSE support in the Hummingbird handler; JSON-RPC layer stays the same. |

Open questions to resolve during Stage 0: exact Codex configuration keys for HTTP MCP servers and bearer tokens in `0.154.0`; whether Claude Code hook payloads include the session ID when `--session-id` is supplied; the skill discovery directory for each CLI under a non-default configuration directory; and whether the MCP port should be fixed or discovered through the runtime socket.
