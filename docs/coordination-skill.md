# Coordination skill

In **Settings → Presets**, select a set and choose **Chauffeur Skill…** on a
preset. Review the bundled guidance and destination, then choose **Install
Skill**. The sheet shows the installed and bundled versions, supports updating
unchanged installations, and offers **Remove Skill…** with confirmation.

The optional `chauffeur` skill explains discovery, messages, bounded inbox
waiting, authorized delegation, retries, and reporting results. It gets the
current session, project, group, peers, parent and delegation IDs from MCP
discovery. Tool descriptions also explain the workflow. Installation never
starts a CLI or adds a session to a group.

## Scope and loading

| CLI | Destination in the selected configuration directory | Evidence on 2026-09-15 |
| --- | --- | --- |
| Codex 0.154.0 | `$CODEX_HOME/skills/chauffeur/SKILL.md` | Native app-server `skills/list`: installed profile lists the expected file, a second profile does not, removal clears discovery |
| Claude Code 2.1.272 | `$CLAUDE_CONFIG_DIR/skills/chauffeur/SKILL.md` | Native SDK initialization lists the command only in the installed profile and drops it after removal |

Codex's [general skill documentation](https://learn.chatgpt.com/docs/build-skills)
lists user and repository `.agents/skills` locations. The configuration-directory
route above is an observed compatibility path for the tested version, not a
claim that all Codex versions support it. Claude's [directory documentation](https://code.claude.com/docs/en/claude-directory)
explicitly relocates personal skills with `CLAUDE_CONFIG_DIR`.

Every session using the same configuration directory can load the guidance,
including sessions started outside Chauffeur. Distinct presets sharing a
directory share this installation. The installation status describes the files;
CLI settings, disabled skill entries, and managed policies can prevent loading.
It does not override those controls.

Restart the CLI if discovery does not refresh. Removing files stops future
discovery; content already loaded in a conversation remains in that
conversation. Claude minimal (`--bare`) mode returned no skill catalog in the
metadata probe, so it is not used as evidence for normal discovery. See
[Claude skill refresh and removal](https://code.claude.com/docs/en/skills#edit-a-skill-during-a-session).

## Files and recovery

The app bundles version `1.0.0` from
`Sources/ChauffeurCore/Resources/Skills/chauffeur/SKILL.md`. Installation creates
the namespaced `skills/chauffeur` directory and its ownership receipt. It leaves
native configuration, credentials, repository instructions, other skills and
MCP servers intact. Installation is explicit; opening Settings or launching a
session never installs the skill.

Chauffeur validates the receipt and exact skill contents before updating or
removing an installation. Existing unmanaged directories, edits, additional
files, links, and inaccessible paths require manual review. Use **Show in
Finder**, preserve any desired changes, and move the conflicting directory
aside before installing the bundled version. An operation is rejected after the
preset path or installed version changes; refresh before trying again.

A private, empty `.chauffeur-skill.lock` in the selected configuration directory
coordinates Chauffeur processes and remains after removal. Temporary install
and retired directories also use the `.chauffeur-` prefix and live outside
`skills/`, so CLI discovery cannot load partial or retired guidance. An
interrupted operation can leave one of these directories. Inspect its contents
before moving or deleting it; Chauffeur does not recursively clean unknown
files. A normal install/update/remove cycle leaves only the lock and any empty
`skills/` parent, alongside the user's existing files.

## Verification

`swift test` exercises install/update/remove, stale revisions, other-profile
rejection, file permissions, missing profiles, concurrent writer locks, and
preservation of edits, foreign directories, extra files, and links. A separate
runtime test proves that a child can discover its own delegation ID and send an
attributed result to its parent without exposing another group's sessions.

```sh
swift build
python3 Prototypes/skill_installation.py
```

This fixture calls the real runtime IPC and the installed native CLIs with
temporary profiles and an empty fixture home. It requests metadata only, sends
no inference prompt, and checks installation, second-profile isolation,
stale-review rejection, and removal. It also accepts
`CHAUFFEUR_RUNTIME_BINARY` to verify the embedded helper in a relocated app.
Signed Debug and Release copies passed this fixture with their build resource
directories hidden. A missing app resource bundle returns an error while the
runtime remains available.
Real model use of the guidance and the broader cross-provider acceptance gate
remain separate checks.
