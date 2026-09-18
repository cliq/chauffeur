# V7 — Session privacy attribution

Status: empirical spike complete for responsibility inheritance and Documents
access; production helper deferred. Recorded 2026-09-18 on macOS 26.6.2 (25G83).

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

## Helper evaluation and next decision

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
