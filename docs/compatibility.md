# CLI and platform compatibility

Last inspected: 2026-09-22. These are observed development-machine versions,
not a completed real-provider support matrix.

| Component | Version | Current evidence |
| --- | --- | --- |
| macOS | 26.6.2 (25G83), M5 Pro / 48 GB | Native app/runtime build; fixture integrations run |
| Swift | 6.2.4 | Swift 6 package builds; concurrency checking enabled |
| Xcode | 26.3 (17C529) | Native app builds and is signed locally |
| tmux | 3.6a | Alternate-screen redraw, resize, input, detachment/restart, native mouse/link forwarding, and sustained bounded capture pass; attachments advertise OSC 8 hyperlinks |
| SwiftTerm | 1.20.0 | Pinned; native terminal views implemented and exercised by the Debug probe |
| Hummingbird | 2.26.0 | Actual loopback MCP requests exercised with fixture credentials |
| Codex | 0.154.0 | Three real sessions/two profiles; authenticated messages, native approvals/completion, scoped stop, explicit resume and runtime reconnect pass. Native UI input/clipboard/resize/history and normal/forced UI quit preserve the process and draft |
| Codex | 0.155.1 | Authenticated cross-provider MCP delegation, messages/results, model/effort overrides, same-session follow-up, retry and retained closure pass; see [orchestration validation](orchestration-validation.md) |
| Claude Code | 2.1.278 | Same orchestration checks pass in both coordinator and worker roles |
| Claude Code | 2.1.272 | Three real sessions/two profiles; native account/process configuration, authenticated messages, permission/completion hooks, scoped stop, explicit resume and runtime reconnect pass; both profiles report the same account |
| Claude Code | 2.1.273 | Basic-terminal launch/resume and checkout recovery pass; native UI input/clipboard/resize/history and normal/forced UI quit preserve the process and draft. Native permission/completion hooks, read-only MCP discovery and normal exit pass; full coordination remains unverified |

`Prototypes/native_profile_selection.py` verifies two concurrent native project
windows per current CLI in the signed Release app. Native `/status` account
displays match the authorized clones, and actual child process indicators prove
the selected configuration directories and removal of inherited fake provider
credentials. Both live basic-mode sessions report **Activity unknown**. The
Codex clones have distinct stored account contexts; Claude A/B share an account,
and the different-account Claude check remains deferred by the user. No model
prompts are sent by this check.

## Capability behavior

### Team setup authentication

The onboarding adapters were checked against Codex 0.155.0 and Claude Code
2.1.278 help and unauthenticated status commands in fresh, isolated temporary
profiles. Codex reports `Not logged in` on stderr; Claude returns JSON status.
Parser fixtures also cover successful status, unknown output, and errors.
Login PTY lifecycle, environment isolation, and verification use fake CLIs in
automated tests. Real browser OAuth completion with separate provider accounts
has not been exercised for this wizard.

Setup uses `codex login` / `codex login status` and
`claude auth login` / `claude auth status --json`. Unsupported status output is
reported as Unable to verify, never inferred from credential-file presence.
This authentication check is independent of the coordination capability matrix
below and does not send a model prompt.

### Agent sessions

The adapter checks `--version` and `--help` before spawning an agent. Codex and
Claude Code are recognized by provider identity, without a version allowlist.
New releases remain coordination candidates; the table records tested versions,
not permitted versions. Missing `--add-dir` support rejects a multi-directory launch.
Missing native conversation IDs disable resume; no global resume selector is used.

Codex 0.154.0 rejects `--add-dir` with a read-only sandbox. Chauffeur reports an
explicit `-s read-only` or `--sandbox read-only` agent preset combined with additional
folders before inspecting or spawning the CLI (including `=read-only` forms).
Remove additional folders or explicitly choose `workspace-write` in the agent preset.
Native configuration and managed policy can also affect effective permissions;
the CLI still enforces them. Ordinary sessions retain their configured permissions.
Delegated orchestration workers explicitly use native YOLO mode, as described in
[orchestration validation](orchestration-validation.md); this does not change presets
or the coordinating session.

`Prototypes/real_checkout_recovery.py` verifies a moved main repository,
replacement primary/additional Git metadata, restored-checkout resume with actual
conversation recall, live-removal refusal, and clean removal preserving the
branch. It passed with Codex 0.154.0 and Claude Code 2.1.273 in basic-terminal
mode, using authorized private profile clones. Hook evidence is recorded
separately below; full coordination remains unverified.

`Prototypes/real_repository_access.py` also passes on these versions using the
signed Release runtime. Real tools read and write the selected primary worktree
and additional repository, including paths with spaces. The main checkout is
not added to the launch and remains unchanged, as does a sibling worktree.
Killing and restarting only the private runtime preserves the real CLI process,
conversation and recorded launch; both providers complete another tool-using
turn after recovery. Claude uses explicit basic-terminal mode. This does not
claim OS sleep/wake or LaunchAgent-update coverage.

`Prototypes/real_terminal_controls.py` uses the same authorized clones in a
signed isolated Debug app. Both current CLIs pass native trust prompts, Unicode
typing, copy/paste, resize, normal/forced UI quit, preserved unsent input and
same-process reattachment, followed by another provider reply. Unicode replies
are searchable and copyable from their captures. Native link/mouse forwarding and
sustained bounded-history rotation have separate fixture evidence in
[implementation status](implementation-status.md). Final workload coverage is
deferred to V2.

`Prototypes/native_attention_smoke.py` passes with Codex 0.154.0 and Claude Code
2.1.273 in an isolated signed Debug app. Each session makes one authenticated,
read-only discovery call with native one-time approval. The app shows Claude's
permission request as **Needs attention**, clears it after tool use, and shows
**Turn finished** after the reply. Completion remains finished after the idle
notification interval. Both CLIs provide native conversation IDs and report
**Exited** after `/exit`. No messages or delegation are exercised. Claude
2.1.273 now has the candidate integration path, still labelled unverified.

Codex's status path is turn completion through `notify`. It does not
prove approval or input status; these remain unknown when no supported event is
available. Claude uses launch-scoped hooks, which may be affected by native trust
or managed policy. Silence and output volume never set completion.

The private native LaunchAgent lifecycle check also passes with Codex 0.154.0
and Claude Code 2.1.273: normal UI quit, launchd crash recovery, the Settings
restart button, bundled-helper replacement, and a real user-performed sleep/wake
cycle. Both providers reply afterward with the original conversation context,
unchanged process/terminal identities, and correct Unicode output. See
[service recovery](service-recovery.md#private-native-service-fixture).

The default Codex and Claude launch routes have real credential and scoped-stop evidence.
Cross-provider orchestration has the dated evidence above; broader release workload
coverage remains open. See
[V3](decisions/V3-mcp-and-status.md). Both baseline CLIs pass native metadata
discovery/isolation/removal checks for the optional
[Chauffeur skill](coordination-skill.md). File installation status does not
override CLI skill policies or establish model use of the guidance.

### Orchestrated follow-up turns

Automatic terminal submission checks provider identity, completion, live pane
identity, cursor state, and an empty recognized composer before every submission.
There is no version allowlist. Busy sessions, drafts, dialogs, and unknown composer
layouts are refused; the coordinator can close and replace a worker instead.
Delegated Claude launches disable prompt suggestions in launch-scoped settings
so ghost suggestions do not occupy the composer. Ordinary sessions keep their settings.

Worker completion is an attributed MCP result, separate from terminal submission
or native turn-finished status. Messages do not wake an idle agent; coordinators
wait for results while their turn remains active.
