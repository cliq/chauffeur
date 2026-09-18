# macOS privacy prompts

Chauffeur sessions run under a signed background runtime and survive quitting
the desktop app. macOS can attribute a session tool's file access to the runtime
and its app even after the original runtime process exits. A diagnostic reporting
that a tool is its own "responsible PID" does not by itself mean that macOS will
request permission for that tool.

The 2026-09-18 [privacy spike](decisions/V7-session-privacy-attribution.md)
confirmed app-level Documents consent for an isolated signed app, including
ad-hoc tools and access first attempted after the app exited. The AppData
follow-up found that one consent covers new tools only while their original
responsible owner remains alive. When it exits, surviving processes and new
panes can prompt again. Removing its signed app bundle can also make macOS name
the tool instead. Relaunching the app does not restore the old consent lifetime.

The installed app already had Full Disk Access, so its successful reads are not
proof of ordinary consent behavior. The isolated fixtures have no such grant.
An independent session owner passed the fixture test across its launching
agent's exit; no production Sessions helper has been added. Desktop and Downloads
remain untested.

## Investigating repeated prompts

Record the exact application named by the prompt and the protected location.
Check **System Settings → Privacy & Security → Files and Folders** for the
application's existing permissions. Documents consent does not establish access
to other protected areas. Keep the installed signed app at its normal path;
deleting the original responsible bundle can break attribution for surviving
sessions. Keeping the bundle alone does not extend AppData consent after its
responsible process exits.

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

## Reproducing AppData safely

Create a signed sandbox fixture containing only a synthetic text file:

```sh
python3 Prototypes/tcc_appdata_fixture.py \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --manifest .local/tcc-appdata/fixture.json
```

The command prints the sentinel path. Pass that exact path as `--access-file`:

```sh
python3 Prototypes/tcc_responsibility.py \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --case launchservices --python-tool /opt/homebrew/bin/python3 \
  --access-file '/the/printed/sentinel/path' \
  --live-panes --capture-tcc --artifacts .local/tcc-appdata/python
```

This reads one byte without printing its contents. The owner uses an empty
`NSDataAccessSecurityPolicy` allowlist to avoid the same-team exemption. Check
that `tcc-events.json` actually contains `kTCCServiceSystemPolicyAppData`; a
successful read without that check does not validate consent. The initial
ad-hoc-signed container attempt did not exercise the protection on this Mac.

Compare `agent-embedded` and `agent-embedded-associated` for the runtime shape.
Use `--case agent-open --stop-launcher --adhoc-tool --live-panes` without
`--python-tool` to test an independent owner and a changed native tool identity.
`--missing-owner` unlinks only the disposable owner after exit and restores a
copy before its relaunch, exposing consent-subject fallback. It never removes
the installed Chauffeur app. Existing grants and caches still affect results;
run one access case at a time and retain the logs.

Clean up the synthetic data through its owning sandbox app:

```sh
python3 Prototypes/tcc_appdata_fixture.py \
  --manifest .local/tcc-appdata/fixture.json --cleanup
```

Cleanup leaves OS-managed empty container metadata and any consent records in
place. The [decision record](decisions/V7-session-privacy-attribution.md#orca-and-mori-source-comparison)
also compares Orca's deliberate per-tool attribution and Mori's normal tmux
launch path. Neither was copied into Chauffeur.
