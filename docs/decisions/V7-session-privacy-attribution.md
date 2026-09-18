# V7 — Session privacy attribution

Status: responsibility, Documents and AppData experiments complete; an independent
session owner is validated in the fixture, production helper integration pending.
Recorded 2026-09-18 on macOS 26.6.2 (25G83).

The AppData follow-up below supersedes the initial helper deferral rationale.
It also found an existing Full Disk Access grant for `dev.cliq.chauffeur`, so
successful installed-app access is not evidence of ordinary folder consent.

## Decision

Do not build a production Sessions helper on the strength of the responsible-PID
measurement alone. Keep V5 session lifetimes unchanged. A signed app launched by
LaunchServices is a viable responsibility source, but a signed LaunchAgent also
confers responsibility, and TCC can retain its original responsible executable
path after the process exits. The installed Release session tree already passed
the scoped Documents-access check. This spike does not establish a production
fix for the reported per-tool prompts.

Use TCC's `AUTHREQ_ATTRIBUTION`, `AUTHREQ_PROMPTING` and selected consent identity,
alongside the PID diagnostic, when investigating a real failing access. In
particular, `responsibility_get_pid_responsible_for_pid(pid) == pid` does **not**
prove that TCC will ask for a tool-specific grant.

## Evidence

`Prototypes/tcc_responsibility.py` builds a disposable Developer ID signed
LSUIElement app, a standalone owner, an embedded non-main executable, and a
separate tool. The tool can be ad-hoc signed and gets a new identifier per run.
Unique jobs and tmux sockets isolate the experiment from live sessions. The
Objective-C fixture uses ordinary spawn APIs; the private responsibility API is
read-only diagnostic code, never linked into Chauffeur.

All cases exercise plain `posix_spawn`, `POSIX_SPAWN_SETPGROUP`, Foundation
`Process`/`NSTask`, double fork plus `setsid` plus `exec`, and tmux's daemonized
server and pane. No responsibility-disclaiming operation is used.

| Owner launch | Descendants' responsible PID while owner lives |
| --- | --- |
| Directly from this existing Chauffeur session | Each descendant itself |
| Directly, with AppKit accessory-app initialization | Each descendant itself |
| `open -n -a` / LaunchServices | Fixture app PID |
| Standalone executable via LaunchAgent | Agent PID |
| Embedded non-main executable via LaunchAgent | Agent PID |
| App main executable via LaunchAgent | Agent PID |
| Each agent variant with `AssociatedBundleIdentifiers` | Same as without it |
| LaunchAgent invoking `open -n -a` | Launched app PID |

After owner termination, existing descendants, the surviving tmux server, and
new panes all report their own PIDs. Relaunching the same signed app does not
change that PID result. This holds with both certificate-signed and ad-hoc tools.

Actual Documents access gives a different and more useful picture:

- The first app-owned tool access prompted for the fixture app. The user TCC
  database recorded an allowed Documents grant for bundle identifier
  `dev.cliq.chauffeur.responsibility-probe`, not the tool path.
- The existing tool and new panes still opened the file after app termination.
  This also worked in a new run that delayed **all** file access until after
  owner exit, and with a newly identified ad-hoc tool. TCC explicitly retained
  the original app identifier and `responsible_path`, even though the accessing
  process was now its own responsible PID. Thus this is more than a repeat
  `open` in the same process, although it is not a cache-free VM experiment.
- A standalone agent's separately signed tool prompted for the **owner's
  executable path**, not the tool's path, after owner exit. That consent was
  recorded as a path grant. The earlier associated-agent run also recorded a
  standalone path grant; adding that plist key is not demonstrated as a fix.
- A non-main executable embedded in the fixture app also allowed Documents
  access after exit, including an ad-hoc tool. TCC recorded the embedded
  executable as the responsible path. There was no additional standalone grant
  for that fixture. This does not prove identical behavior for every service.
- A fresh ad-hoc tool run from the current installed Chauffeur session opened
  the same file, with no new tool-specific Documents grant observed. Installed
  session attribution logs retained
  `/Applications/Chauffeur.app/Contents/MacOS/ChauffeurRuntime` despite self-PID
  results. A Documents grant for `dev.cliq.chauffeur` already existed. Successful
  access here is not proof of a new consent decision; inherited/cached access
  and existing grants remain part of this environment.

Private evidence is under `.local/tcc-matrix-final-code/`,
`.local/tcc-access-ls-adhoc/`, `.local/tcc-access-embedded-adhoc/`,
`.local/tcc-access-bare-unique/`, `.local/tcc-access-installed/`, and
`.local/tcc-responsibility/`. Earlier exploratory runs are retained separately.
The scoped TCC logs and read-only database observations distinguish bundle and
path grants; permission database contents are not committed.

`make install` built, signed, verified and installed Release. The requested
`launchctl kickstart -k gui/$(id -u)/dev.chauffeur.runtime` ran afterward. The live
tmux server retained PID 810. One pane disappeared during the install window;
another ended before a second isolated restart, so the broad interval is not
claimed as a complete session-continuity pass. The second restart preserved all
seven then-present pane identities and PIDs exactly. No live tmux server was
terminated by the harness.

## Initial helper evaluation

A future `Chauffeur Sessions.app` can have a distinct stable bundle identifier,
Developer ID signature, native LSUIElement executable, and own the tmux launch.
The runtime can launch it through LaunchServices independently of the desktop
UI. The agent-to-`open` experiment verifies that launch route. This would retain
the normal V5 rule that quitting the desktop app leaves sessions alive. An
SMAppService login-item registration for that helper was **not** implemented or
tested. A separately identified helper would normally have its own consent
identity; the experiment does not show how to make it use `dev.cliq.chauffeur`.

The owner need not remain alive for the tested Documents grant to work, provided
the original signed app is still present. Deleting, moving, or replacing that
owner's app while descendants survive is untested. So are helper updates,
reboot/login, Desktop, Downloads, AppData, and an actual Homebrew upgrade. A
production helper would need a policy for its update path, surviving servers,
and new sessions after relaunch; merely restarting it does not adopt old PIDs.

Before adding that component, capture a real failing request's TCC service,
accessor and responsible paths, selected grant identity, and signing
requirements. Compare those with the installed runtime and any old build paths.
Old/deleted responsible paths and service-specific attribution are hypotheses,
not established causes. Reproduce AppData separately in a disposable fixture or
VM. The fallback "launchd cannot confer responsibility" is disproved by this
spike, so it would be incorrect to document it as a platform limitation.

## References

Apple describes responsible-code attribution, stable signing requirements,
LaunchAgent bundle association, and VM-based TCC testing in
[On File System Permissions](https://developer.apple.com/forums/thread/678819).
Its [environment constraints session](https://developer.apple.com/videos/play/wwdc2023/10266/)
also distinguishes parent and responsible processes. Those references inform
the experiment; the results above are measurements on this Mac, not a promise
about undocumented APIs across macOS versions.

## AppData follow-up: lifetime matters

Historical unified logs confirm real Homebrew Python prompts on this Mac. At
13:13:52 TCC selected the Python launcher path for Documents; at 13:14:27 and
13:15:54 it selected the same path for AppData in different Python processes.
These are consent-subject observations, not inferences from the PID diagnostic.
The precise historical event that lost app attribution remains unproved.

Apple's [WWDC23 privacy explanation](https://developer.apple.com/videos/play/wwdc2023/10053/)
distinguishes AppData from persistent folder consent: it lasts while the app is
open. Full Disk Access and same-team container access can suppress the prompt.
An explicit `NSDataAccessSecurityPolicy` allowlist replaces the same-team
exemption. This explains why Documents results cannot predict AppData lifetime.

### Controlled target and measurement

`Prototypes/tcc_appdata_fixture.py` creates a separately signed sandbox app with
an empty data-access allowlist. That app writes one synthetic text file in its
own OS-created container. `secinitd` logs confirm the policy was applied. Neither
the sandbox fixture nor the accessor app has Full Disk Access. An initial
ad-hoc-signed target did not trigger AppData checks and was discarded as an
invalid protection control. No real application's private files are read.

Native and Python leaves now read exactly one byte and record only the count,
errno and process identity. The Homebrew Python launcher is actually exec'd,
including its framework-app trampoline; the test does not substitute a native
tool for Python. `--capture-tcc` retains fixture-related requests by path **and
PID**, then joins the request IDs. PID matching is necessary when losing the
owner's path removes that path from TCC's messages.

### Results

| Experiment | While original owner lives | After original owner exits |
| --- | --- | --- |
| LaunchServices app → tmux → Python | One app-level AppData consent covers subsequent panes | Existing process and fresh panes each prompt again for the app |
| Embedded LaunchAgent → tmux → Python | Same shared consent | Same repeated app prompts |
| Embedded agent plus `AssociatedBundleIdentifiers` | Same shared consent | Same repeated app prompts; not a lifetime fix |
| Agent opens Sessions fixture; launching agent then exits | Sessions owner remains responsible; new and changed ad-hoc tools need no additional consent | Killing Sessions owner produces the repeated-prompt behavior |
| Owner exits, then its bundle is unlinked | App-level consent before exit | TCC selects `org.python.python` while the owner bundle is absent |
| Owner exits, then its bundle is renamed | App identity remains resolvable at its new path | AppData still prompts again because the owner exited |

In the unlink test, restoring a copy of the bundle at the original path restored
the app-level consent subject for a new pane. It did not reconnect that pane to
the new owner PID or restore the original AppData lifetime. The two prompts while
the bundle was absent named `org.python.python`; the original real incident
named Python's launcher path. This reproduces **fallback to tool identity**, not
the exact historical identity-selection path or proof of the original cause.

Each complete protected run recorded four AppData prompts: the initial owner,
the existing pane after owner exit, a new pane, and a pane after owner relaunch.
Runs with additional panes while the owner lived still recorded only those four
prompts. One-byte reads succeeded after the user responded to the dialogs.
The changed native tool has a new ad-hoc signing identifier; this models changing
tool identity, not a real Homebrew upgrade. In Python runs it is the trampoline
that changes, so those runs alone do not establish Python-upgrade behavior.

The installed tree read the fixture without new prompts, but a read-only check
of the system TCC database found an existing allowed Full Disk Access grant for
`dev.cliq.chauffeur`, predating this work. This masks ordinary consent behavior
and is explicitly **not** an installed production-fix pass. No grants were
reset, added programmatically, or changed by the harness.

Private evidence is under `.local/tcc-appdata/`: `original-python-prompts.json`,
`policy-python/`, `agent-python/`, `associated-python/`, `missing-python/` (the
earlier rename experiment), `unlinked-python/`, `independent-owner/`,
`installed-python/`, `container-policy.log`, and `current-grants.json`.

### Resulting implementation direction

Use an independent signed session owner for new tmux servers if pursuing the
terminal-style AppData experience. The fixture verifies a runtime-like agent
opening that app through LaunchServices, then exiting while the owner and
sessions retain their consent. This gives a reason for a Sessions helper beyond
bundle naming: its lifetime must span UI quits and routine runtime restarts.
The achievable policy is **one AppData consent per owner lifetime**, not an
unconditional permanent grant for all protected services.

Do not adopt Orca's per-tool `login` wrapper (see comparison below). Do not kill
or migrate existing live sessions to retrofit the owner. Production integration
needs authenticated local IPC, idempotent start/reconnect, ownership of fresh
tmux servers, and a drain policy for old servers. Keep old owner processes and
their signed bundles available while they own sessions; stage a new owner for
new sessions on update. A crashed owner's surviving sessions must retain V5
continuity, but renewed AppData prompts are a limitation to expose, not a reason
to kill those sessions. A fresh app with the same identity cannot adopt old
responsibility PIDs through any API exercised here.

The installer currently removes the installed app before copying its replacement.
The unlink experiment identifies this as a plausible attribution hazard, but
renaming an old bundle is not by itself a complete AppData fix: stopping its
responsible process still ends shared consent. The fixture does not implement
the production installer or helper-update protocol. Neither actual UI quit with
the proposed helper, production runtime replacement, nor reboot/login has been
tested for that new architecture. The existing installed Release and kickstart
checks above remain baseline measurements.

### Orca and Mori source comparison

Read-only repository snapshots were inspected on 2026-09-18, without running
either product. These are source findings, not macOS acceptance results.

- **Orca**, commit `47d107cf2ea3f5e856dd328f5c90643a2e81c990`, uses a
  [`login -flpq` shell wrapper](https://github.com/stablyai/orca/blob/47d107cf2ea3f5e856dd328f5c90643a2e81c990/src/main/providers/macos-tcc-login-shell.ts)
  expressly to give children separate TCC identities, avoiding repeated grants
  for signed tools such as `op`. It probes PAM support and falls back to a plain
  spawn. This is the opposite of Chauffeur's requested shared identity.
- Orca also records the daemon's spawning executable and
  [checks whether its path still exists](https://github.com/stablyai/orca/blob/47d107cf2ea3f5e856dd328f5c90643a2e81c990/src/main/daemon/daemon-tcc-attribution.ts).
  Its [recovery policy](https://github.com/stablyai/orca/blob/47d107cf2ea3f5e856dd328f5c90643a2e81c990/src/main/daemon/daemon-pty-daemon-recovery.ts)
  preserves a daemon with live or unknown session inventory and replaces it only
  after sessions drain. That continuity policy is relevant to Chauffeur. Path
  existence alone would not prove the current process's consent lifetime.
- **Mori**, commit `ff206eec6b7c62ccebfa0a8c38499d2792bfccfe`, creates detached
  tmux sessions through its
  [backend](https://github.com/vaayne/mori/blob/ff206eec6b7c62ccebfa0a8c38499d2792bfccfe/Packages/MoriTmux/Sources/MoriTmux/TmuxBackend.swift)
  and ordinary Foundation
  [`Process` runner](https://github.com/vaayne/mori/blob/ff206eec6b7c62ccebfa0a8c38499d2792bfccfe/Packages/MoriTmux/Sources/MoriTmux/TmuxCommandRunner.swift).
  Its [app termination handler](https://github.com/vaayne/mori/blob/ff206eec6b7c62ccebfa0a8c38499d2792bfccfe/Sources/Mori/App/AppDelegate.swift)
  saves state and tears down UI surfaces. No dedicated TCC attribution repair
  or independent session-owner helper was found in the inspected app/tmux
  sources; this is not evidence that its surviving sessions avoid AppData prompts.
