# Worktrees and cleanup

Expand a repository in the sidebar to see its other Git worktrees, including
external checkouts. Each row shows its branch and directory name; hover for the
full path. Select a worktree to open its repository's manager, or use its context
menu to reveal it in Finder. Missing registered worktrees stay visible with their
availability status. The repository row itself represents its registered checkout.

Open **Manage Worktrees…** in a project window, choose a repository, and either register
an existing Git worktree or create one with a branch and base ref. Creation shows
the destination under Chauffeur's managed storage. The resolved base commit is
recorded separately from the branch's current state. A failed agent launch
retains the checkout for another explicit launch.

## Create a worktree and start an agent

Expand a repository in the sidebar and choose **New Worktree & Session…**, or
choose the same action from the repository's context menu. Select an agent preset
and group, enter a new branch name and a base reference (initially `HEAD`), and
review the destination. Add an optional initial task, then choose **Create &
Launch**. The regular **New Session** sheet also offers **New worktree…** in its
**Work in** menu.

The sheet keeps its action buttons visible while the settings scroll. Creation
and launch show progress and prevent duplicate submissions. If agent startup
fails, the sheet selects the new worktree and keeps it available for another
launch. Fix the reported problem, then use **Launch Session** for a fresh attempt.
**Check Previous Attempt** recovers the original result after an uncertain response;
an already recorded failed attempt opens that session without starting it again.

Worktree creation requests carry a persistent retry ID. Repeated or concurrent
requests with the same fields return the same recorded checkout, including after
a runtime restart. Reusing the ID with different fields is rejected. A removed
checkout is not recreated by a retry. If Git creates the checkout but saving its
record fails, the error reports its retained path: refresh Git inventory in the
manager and register that checkout. Git creation and metadata storage are separate
operations; an abrupt runtime exit between them requires the same recovery.

## External changes

The background service checks Git inventory when it starts, then waits five
seconds between completed scans. Checks continue while all app windows are
closed. **Refresh Git Inventory** requests a scan immediately, joining any scan
already in progress. Slow or unavailable disks can lengthen the interval; the
view shows when its inventory was observed and reports unavailable sources.

Inventory uses [`git worktree list --porcelain -z`](https://git-scm.com/docs/git-worktree#_list_output_format),
including paths containing newlines, locked worktrees, and stale entries. Each
repository is scanned once per pass, even when multiple project folders or
worktrees refer to it. Missing source folders can be supplemented by another
available registered checkout from the same repository.

Newly created and registered records include an identity derived from the file
identity and creation time of Git's administrative directory, located through
`git rev-parse --absolute-git-dir`. This lets the service follow a
`git worktree move` while retaining the Chauffeur worktree ID, updating its path
and current branch, and preserving its original base commit. Moving outside
Chauffeur's managed storage makes the checkout external: subsequent cleanup is
an unregister action that preserves its files.

Deleting and recreating a checkout at the same path does not transfer ownership
to the replacement. The old record becomes missing; explicitly register the new
checkout to use it. Existing records without a Git identity acquire one only
when their recorded path is still present in the expected repository's inventory.
If an older record was already moved before that observation, its relationship
to a new path is unproven; register the current checkout explicitly.

If a folder was moved directly in Finder or a shell and Git still lists its old
path, Chauffeur reports the stale inventory. Git documents
[`git worktree repair`](https://git-scm.com/docs/git-worktree#_details) for restoring
that relationship. Chauffeur does not repair or prune Git's bookkeeping
automatically.

### Moving the main repository

After moving the main repository on the same filesystem, relink its folder in
**Edit Project…** and repair Git's linked-worktree bookkeeping if needed using
[`git worktree repair`](https://git-scm.com/docs/git-worktree#_details) from the new
main repository. Refresh Git inventory. Repository identity now follows the
filesystem identity of Git's common directory, so registered worktrees retain
their Chauffeur IDs, original base commits, and existing managed paths. New
checkouts use the current repository ID under managed storage.

Older records used a hash of the common directory's path. Reconciliation upgrades
them after matching their recorded checkout identity, or their original path in
the original repository when no checkout identity was saved. Registering a known
checkout after a move reuses its record. A copy, clone, or move to a different
filesystem has different file identities and needs explicit registration; it
does not inherit cleanup ownership from the original.

## Live sessions and sharing

Session launch snapshots keep their original paths. A worktree move updates the
worktree record, not the historical launch snapshot. New sessions record Git
worktree identities for primary and additional directories so a move does not
hide a live session from cleanup checks or shared-checkout warnings. This also
applies when the session selected a normal project folder pointing into a
worktree instead of selecting a worktree record.

**Resume Conversation** checks every original primary and additional directory
before changing the ended session or its terminal. New snapshots bind each path
to its directory identity and, when present, Git's administrative-directory
identity. Missing paths, replacement directories, changed symlink targets, and
replacement Git metadata prevent resume. Ordinary file edits and branch changes
do not replace those identities. Restoring the original checkout at its original
path allows the same native conversation and profile to resume.

Relinking a project or refreshing worktrees does not move a conversation's
historical launch path. For a moved conversation checkout, restore that path to
resume or create a new session at its new location. Older snapshots can verify
Git identity when they recorded one for every path; incomplete legacy identity
lists require a new session. Rejection preserves the ended session and terminal
history. See [conversation recovery](service-recovery.md#resuming-after-a-checkout-changes).

Launching, resuming, and removing checkouts use runtime reservations that remain
held while filesystem checks, Git commands, and process startup are awaiting
results. If removal has started, a launch needing that primary or additional
directory fails with `worktree_busy`. If a launch has reserved it first, removal
fails with `active_worktree`. Metadata reconciliation cannot overwrite an
in-flight removal. Concurrent launches into the same checkout require explicit
sharing; a pending launch does not silently imply consent to share.

These reservations coordinate Chauffeur operations. Other Git clients or shell
commands can still change a filesystem concurrently. Removal rechecks Git's
inventory, identity, lock state, and cleanliness, and uses Git's normal removal
command without a force option.

## Removing or unregistering

The confirmation identifies the path and branch. Removal requires a managed
checkout inside Chauffeur's storage, no live or starting sessions using it, no
Git lock, and no modified or untracked files. It preserves the branch. Closing a
session, tab, project window, or app does not remove a checkout.

An external checkout can be unregistered while its files and session history
remain in place. If an external metadata edit conflicts with an app operation,
refresh before retrying; the runtime does not overwrite the edit. Missing or
inaccessible checkout records remain visible for recovery.

## Verification

- Swift tests exercise clean/dirty/untracked/active removal, independent file
  changes, branch preservation, collisions, moves, replacement at the same path,
  newline paths, missing sources, and reservation interleavings. Creation retry
  tests cover concurrent callers, runtime restart, conflicting fields, removed
  records, legacy requests, and retained files after agent startup failure.
- Repository relocation tests move a real Git repository, repair its linked
  worktrees, relink the project, migrate legacy identities, reopen the runtime,
  and remove a clean managed checkout. Resume fixtures replace primary and
  additional Git metadata, replace a plain folder or its symlink target, and
  restore the original. They verify refusal preserves the ended terminal and
  successful recovery uses the same native conversation/profile. These agents
  are fixtures; no provider account or real conversation is involved.
- `Prototypes/real_checkout_recovery.py` exercises the same recovery through real
  Codex 0.154.0 and Claude Code 2.1.273 (basic-terminal mode). Each resumed
  conversation recalls a token from its first turn without receiving it again.
  Both reject removal while live, then permit clean managed removal after Stop
  while preserving the branch. Private reports are under
  `.local/checkout-recovery-{codex,claude}/`; these runs use only authorized clones.
- `python3 Prototypes/quick_session_smoke.py` opens the actual new-worktree sheet
  through the repository action in an isolated signed Debug app. A temporary Git
  repo and fixture agent verify invalid-branch recovery, retained worktree after
  agent failure, fresh launch into the same checkout, literal task forwarding,
  and selection of the launched session. Screenshots and its report are saved
  in `.build/quick-session-artifacts/`.
- `python3 Prototypes/worktree_smoke.py` runs an isolated runtime and real Git
  repositories. A fixture fsmonitor hook pauses Git status during removal; both
  primary and additional-directory launches must be rejected. This test failed
  against the previous Release build because a launch entered the checkout.
- The same fixture observes external add/move/branch/replacement changes without
  a UI or explicit refresh, verifies external unregister preserves files, and
  verifies a moved worktree used through a regular folder remains protected.

Remaining end-to-end acceptance includes native worktree-control interactions.
Whole-repository relocation and checkout-replacement recovery have both fixture
and real-provider evidence; Claude 2.1.273 was tested in basic-terminal mode and
its coordination/status compatibility remains unverified. Final multi-project
workload testing is tracked in V2.
