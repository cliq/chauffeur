# macOS privacy prompts

Chauffeur sessions run under a signed background runtime and survive quitting
the desktop app. macOS can attribute a session tool's file access to the runtime
and its app even after the original runtime process exits. A diagnostic reporting
that a tool is its own "responsible PID" does not by itself mean that macOS will
request permission for that tool.

The 2026-09-18 [privacy spike](decisions/V7-session-privacy-attribution.md)
confirmed app-level Documents consent for an isolated signed app, including
ad-hoc tools and access first attempted after the app exited. The installed
Release session also passed the scoped Documents check. It did not reproduce or
resolve all reported tool-specific prompts, and did not test AppData, Desktop,
or Downloads consent. No production Sessions helper has been added.

## Investigating repeated prompts

Record the exact application named by the prompt and the protected location.
Check **System Settings → Privacy & Security → Files and Folders** for the
application's existing permissions. Documents consent does not establish access
to other protected areas. Keep the installed signed app at its normal path;
the effect of deleting old responsible app builds while sessions survive has
not been established by this spike.

For a developer reproduction, capture the relevant `com.apple.TCC` unified-log
entries. `AUTHREQ_ATTRIBUTION` distinguishes the accessing executable from the
responsible executable; `AUTHREQ_PROMPTING` identifies the proposed grant.
Compare those paths with the current installed runtime, its signature, and any
old build locations. Inspecting a consent database is read-only diagnostic work,
not a way to grant access. Do not reset the user's grants to run this probe.

If access is blocking work, a checkout outside Documents, Desktop and Downloads
avoids those folder-specific protections, but not other apps' protected data.
If appropriate for the task, the user can grant an affected tool Full Disk Access
in System Settings. That is broad access, and a path/ad-hoc tool identity can
change on a Homebrew update; it is a workaround rather than Chauffeur's desired
consent model. The helper/runtime architecture is still under evaluation.

## Reproducing the spike

Run from a Chauffeur session for the same direct-launch baseline:

```sh
python3 Prototypes/tcc_responsibility.py \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --adhoc-tool
```

The default run does not attempt protected-file access. It creates temporary
signed fixtures, unique LaunchAgents, and private tmux sockets, measures before
and after owner exit, then stops those fixtures. JSON evidence and copies of the
fixture files go under `.local/tcc-responsibility/`. It never kills Chauffeur's
tmux server or changes responsibility using private APIs.

To test real consent, supply a disposable file you created in Documents. This
may show macOS prompts; the harness does not answer them. Run access cases one
at a time and inspect both the results and TCC attribution logs:

```sh
python3 Prototypes/tcc_responsibility.py \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --case launchservices --adhoc-tool \
  --access-file "$HOME/Documents/your-disposable-probe.txt" \
  --access-after-exit-only --artifacts .local/tcc-access
```

Omit `--access-after-exit-only` to compare access before and after owner exit.
Other cases include `agent-bare`, `agent-embedded`, their `-associated` variants,
and `agent-open`. Consent chosen in a dialog remains in macOS after cleanup;
the harness removes temporary processes/files, not the user's consent records.
Reuse of existing grants or system caches is possible. A fresh VM is the stronger
test for initial prompts and service-specific behavior.
