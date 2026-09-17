# Native iOS remote control — POC requirements

- Date: 2026-09-17
- Status: Draft; user-confirmed scope with proposed implementation defaults below.
- Audience: Personal use on an iPhone and an existing Chauffeur Mac.
- Priority: Prove communication and terminal interaction before designing the final mobile UX.

## 1. Outcome

From an iPhone on the same local network as the Mac, browse active Chauffeur sessions across projects, interact with their real terminals, and launch new agent or shell sessions in existing or new worktrees. Create and switch terminal tabs as on macOS.

The Mac remains the execution host and source of truth. The phone is a remote client; repositories, worktrees, CLI installations, credentials, and processes remain on the Mac.

## 2. Confirmed scope

| Area | Requirement |
| --- | --- |
| Platform | Native iOS app. |
| Connectivity | Same local network as the Mac. |
| Browse | View all active sessions across all existing projects, including projects without an open desktop window. |
| Terminal | A proper interactive terminal, with live output and terminal input. |
| Launch | Select an existing project, repository/folder, existing or new worktree, and agent or shell. |
| Tabs | Create additional session tabs and switch between them, as on macOS. |
| UI | Only the browsing and controls needed to prove these workflows. Final UX comes later. |

## 3. Proposed POC defaults

These are scope defaults, not additional user decisions. They can change during the technical spikes without redesigning the product.

- Connect to one Mac at a time. Manual host entry and explicit pairing are sufficient; automatic discovery is optional.
- Start with iPhone; an optimized iPad layout is deferred.
- Use agent presets already configured for the selected project. Default to the project's default group, with existing-group selection if needed; no group or preset editor.
- Allow an optional session title and initial agent prompt. A prompt is not required to open an interactive agent.
- A tab is a view of a session. **New Tab** launches another agent or shell in the current checkout by default, with a way to change the launch selection. Opening an existing session does not create another process.
- Tab selection and ordering are local to each device. Session identities and launch results are shared with macOS; exact tab layouts need not synchronize.
- Use explicit terminal-control handoff between desktop and mobile. One client controls input and terminal size at a time; simultaneous independent writers are deferred.

## 4. Minimum user flows

### Connect and browse

1. Enable remote access on the Mac and pair the iPhone.
2. Connect over the local network.
3. Show active sessions grouped by project, with title, agent/shell type, checkout or branch, and available lifecycle/attention state.
4. Select a session to open its terminal. Offer project selection for new launches even when a project has no active sessions.

The list must include sessions created on either device. Show empty, connecting, disconnected, and unavailable-host states. Refresh after launch, reconnect, and lifecycle changes; manual refresh is an acceptable POC fallback. Disconnected data must be visibly stale rather than presented as current.

“Active” means the runtime reports the session as live, including sessions waiting for input. Do not infer agent activity or attention from terminal text when the runtime has no supported signal. If an open session exits, show its ended state without silently relaunching it.

### Create a session

1. Select an existing project and one of its registered repositories/folders.
2. Choose its main checkout, an existing worktree, or **New Worktree**.
3. For a new worktree, provide a branch name and base ref, using desktop-equivalent defaults and validation. Show the destination before launch. Non-Git folders support existing-folder launches only.
4. Choose **Agent** and an existing preset, or **Shell**.
5. Launch, add the resulting session as a tab, and attach its terminal.

Use the Mac's existing launch rules, including executable/configuration validation and shared-checkout checks. Shells follow existing shell launch behavior. Report unavailable folders, invalid refs, branch conflicts, and failed launches with a recoverable error.

Retries after a timeout or disconnection must resolve to the original operation, not duplicate a session or worktree. If worktree creation succeeds but launch fails, retain and display the worktree for retry, matching desktop behavior. Closing a launch screen is not proof that an operation was cancelled; reconcile its result on reconnect.

### Interact and create tabs

1. Open a live session and acquire terminal control if another client owns it.
2. Read output, type commands or prompts, respond to native CLI approvals, and interrupt using Control-C.
3. Create another tab in the same checkout, choosing an agent or shell.
4. Switch between tabs and the cross-project session list.
5. Return to the desktop and take control of the same running session.

Switching tabs, closing a mobile tab, backgrounding the app, or disconnecting must not terminate the session. Session stopping and other lifecycle-management UI are deferred; normal shell exit and terminal interrupt remain available.

## 5. Terminal contract

The POC must render a terminal byte stream, not screenshots, a log viewer, or a chat-style replacement.

Required behavior:

- ANSI colors, cursor movement, screen clearing, alternate-screen applications, and Unicode render correctly for the supported agent CLIs and shell fixtures.
- Software keyboard input, Return, Backspace, arrows, Tab, Escape, and Control combinations are available. Include minimal accessory controls for keys absent from the iOS keyboard. Support hardware-keyboard input as well.
- Terminal input preserves literal text; autocorrection and smart punctuation must not rewrite commands. Support selection/copy and paste, including multiline and bracketed paste where enabled by the terminal application.
- Live output, usable bounded scrollback, and a correct current screen on reattachment. Full desktop history search/archive parity is deferred.
- Resize the remote terminal when its visible cell dimensions change, including orientation and keyboard appearance. The controlling client owns the terminal size.
- A new attachment restores terminal state and continues the same process, including already-entered but unsubmitted input.
- A terminal-control transfer is explicit and visible. Revoke the previous controller's input and resize rights before accepting the new controller's events. A stale client must not keep typing or repeatedly reclaim control.
- Loss of connection disables input and shows connection state. Do not queue commands offline or replay unacknowledged terminal input after reconnect; terminal keystrokes are not retryable launch operations.

The exact gestures, key accessory layout, font controls, and final tab design remain open. Working interaction on a physical iPhone is the acceptance standard.

## 6. Communication and lifetime

Expose only the remote operations needed for listing projects/checkouts/presets/sessions, creating worktrees and sessions, resolving launch results, and attaching/input/resizing/detaching terminals. Reuse existing runtime models and validation rather than maintaining separate mobile session state.

The connection must distinguish metadata responses, operation errors, terminal bytes, and lifecycle events. Preserve byte ordering, correlate requests and results, and negotiate protocol compatibility. Bound output buffering so a slow or suspended phone cannot exhaust runtime memory; if a stream cannot continue correctly, detach and restore through a fresh attachment rather than silently dropping terminal bytes.

Remote access is opt-in. Pairing must establish trust in the host and authorize the device; protect terminal contents and credentials in transit, and allow the Mac to revoke access. Same-network presence alone is not authorization. Pairing UI can be basic. Do not expose an unauthenticated shell endpoint or simply publish the existing local IPC interface to the network.

Assume the Mac is awake, network-reachable, and its runtime is running. Closing desktop windows or quitting the desktop UI must not break remote access. Mac sleep or network loss may disconnect the phone; explain the unavailable state and reconnect when reachable. Wake-on-LAN and internet access are out of scope.

On iOS backgrounding, a network connection may end. Foregrounding must refresh metadata and reattach to the same process without replaying the initial task. The Mac continues running sessions while the phone is disconnected or terminated.

## 7. Existing foundations and technical gates

The current desktop implementation uses tmux to own session PTYs and SwiftTerm to render attachments; see [terminal continuity](decisions/V1-terminal-continuity.md). Existing worktree and launch semantics are documented in [worktrees](worktrees.md) and represented by `LaunchRequest` and `WorktreeCreationRequest` in `Sources/ChauffeurCore/LaunchConfiguration.swift`.

`Sources/ChauffeurRuntimeKit/TmuxHost.swift` currently allows one attachment per session and rejects an additional attachment. Remote control therefore needs an explicit ownership-transfer path, including desktop behavior when it loses control. Mobile cannot assume it can attach alongside an existing desktop terminal unchanged.

Resolve these gates before building more UI:

| Gate | Required evidence |
| --- | --- |
| LAN communication | A paired physical iPhone lists real projects and sessions; unauthorized devices cannot list, launch, or attach. Record the selected transport and trust mechanism. |
| iOS terminal | A candidate native terminal component renders a shell and both supported agent CLIs, handles keyboard controls, paste, and resize. Reuse SwiftTerm if suitable; iOS integration is not yet validated by this PRD. |
| Attachment handoff | Transfer a session between macOS and iOS with the same process and usable terminal state; stale input/resize events are rejected. |
| Launch reliability | Mobile launches agents and shells in existing/new worktrees; lost responses and retries create only one requested worktree/session. |
| Recovery | Network loss, iOS backgrounding/termination, and runtime reconnection preserve live sessions and correctly report missing/ended ones. |

Transport, terminal-library integration, pairing mechanics, and minimum iOS version are implementation decisions to record after these spikes. No mobile capability is claimed as implemented or verified by this document.

## 8. Explicitly deferred

- Final visual design, complete navigation, onboarding polish, and full macOS feature parity.
- Internet connectivity, relays, cloud accounts, multi-user access, or managing multiple Macs simultaneously.
- Project creation/editing, repository registration, agent installation/sign-in, preset editing, and group management.
- Worktree deletion/pruning, session-history management, conversation resume UI, and session-stop controls.
- Split panes, file browsing/editing, diffs, Git/PR workflows, notifications, and agent coordination UI.
- Simultaneous terminal writers and synchronized desktop/mobile tab layouts.
- App Store release work and optimized iPad UX.

## 9. Acceptance and delivery

Deliver in three increments: (1) paired LAN connection and existing-session terminal attachment; (2) launch selection, worktree creation, and tabs; (3) handoff/recovery hardening and end-to-end validation. Only minimal UI is needed at each step.

The POC is complete when the following pass on a physical iPhone and the development Mac:

1. Browse live agent and shell sessions across at least two projects, including one without an open desktop window. A project with no sessions is still selectable for launch.
2. Attach to existing Codex, Claude Code, and shell sessions. Exercise prompts/approvals, Control-C, Escape, arrows, Tab, Unicode, copy/paste, scrollback, and a full-screen terminal fixture.
3. Launch an agent and a shell in an existing checkout, and launch each kind in a newly created worktree. Verify project, checkout, preset, and process identity on the Mac.
4. Create multiple tabs in one checkout and switch among them and another project's session. Closing a tab leaves its process running.
5. Transfer terminal control in both directions while desktop and phone are connected. Verify only the owner can type/resize, correct redraw after transfer, and preservation of unsent input.
6. Rotate the phone and show/hide its keyboard. The terminal remains usable and receives appropriate dimensions without desktop resize contention.
7. Disconnect Wi-Fi, background and terminate the iOS app, and quit the desktop UI. Reconnect to the same live sessions with current state, no duplicated launches, and no replayed keystrokes.
8. Lose a launch response and retry; verify exactly one session and worktree. Exercise invalid branch/ref, unavailable checkout/preset, and agent launch failure after successful worktree creation.
9. Reject unauthorized or revoked devices. Report an unreachable host and incompatible protocol clearly.

Record device/OS, Mac/runtime, terminal-component, and CLI versions, along with observed limitations. On an ordinary local Wi-Fi connection, input echo and output should feel interactive; proposed measurement targets are p95 shell input-to-visible-echo under 150 ms and warm attachment under two seconds, excluding provider response time. Record measurements before treating these targets as proven.
