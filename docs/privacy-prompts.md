# macOS privacy prompts

New sessions started by the installed app use **Chauffeur Sessions**, a signed
background app that owns their terminal server. It stays alive when you quit
Chauffeur, restart the background service, or stop and restart that service.
macOS can therefore ask for access on behalf of Chauffeur Sessions instead of
separately for Python, rg and other tools.

Documents consent is normally persistent. Other apps' data (AppData) has a
shorter lifetime: one consent covers new tools and sessions while their original
Sessions owner remains alive. It is **not** a permanent grant across all
protected services. Reboot, logout, a helper crash, or explicitly quitting the
helper ends that lifetime. An updated helper can start a new consent lifetime;
updating a tool inside an existing session does not itself replace the owner.
Desktop, Downloads and an actual Homebrew upgrade remain untested.

Existing sessions are preserved, including sessions started before this change.
They keep their previous attribution. Start a new session to use the new owner.
If a Sessions helper crashes, its terminals survive and remain accessible, but
those old terminals may prompt repeatedly for AppData again. New sessions use
a fresh owner. Restarting a helper cannot adopt an old process tree.

Chauffeur keeps signed helper copies under
`~/Library/Application Support/Chauffeur/session-apps/` so replacing the installed
app does not remove a live owner's executable. Do not delete these copies while
sessions are running. Old helpers exit after their sessions drain when a newer
helper has taken over new launches. The current helper stays alive while idle.
Cached copies are retained; automatic disk cleanup is not implemented yet.

See the [measurements](decisions/V7-session-privacy-attribution.md) and
[implementation decision](decisions/V8-independent-session-owner.md). A tool
reporting itself as its responsible PID does not alone identify TCC's consent
subject. The main Chauffeur app already had Full Disk Access during the spike;
that successful access was not proof of ordinary folder consent. The installed
Sessions helper was then tested separately against synthetic protected AppData:
TCC named `dev.cliq.chauffeur.sessions`, with one prompt shared across new Python
sessions and runtime restarts, and a new prompt for the updated helper owner.

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
consent model. For new sessions, the relevant app permission is Chauffeur Sessions.

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

## Installed helper acceptance

After `make install` and restarting the installed runtime, run:

```sh
python3 Prototypes/session_owner_acceptance.py \
  --identity 'Developer ID Application: Your Name (TEAMID)'
```

This uses the installed Release runtime with a unique temporary LaunchAgent,
data root and servers. It checks shell/Python responsibility, runtime restart
and stop/relaunch, signed helper updates, preserved bundle copies, retirement
and owner-crash recovery. Add `--quit-ui` to exercise the normal desktop Quit
choice that keeps terminals running (requires Accessibility for System Events).
Add `--access-file '/synthetic/sentinel/path'` to check one-byte protected access;
macOS may present dialogs, which the harness leaves for the user. Responsibility
checks alone do not prove shared consent. Results go to
`.local/sessions-acceptance/results.json`; no real app's private data is read.
