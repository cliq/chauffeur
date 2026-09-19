# Team onboarding wizard

Date: 2026-09-19
Branch: `feat/onboarding-wizard`
Status: Design for review; implementation has not started.

## Intent and agreed direction

Help someone with personal, work, or client accounts reach a working Chauffeur team setup without knowing how agent configuration directories work. Also provide a short path for single-account users and users with existing directories.

Use a team-first wizard, with discovery as a shortcut. Ask about account count separately for Codex and Claude Code. Teams may share an agent configuration, including mixed setups where only one agent has separate accounts. A team is a Chauffeur grouping, not a provider organization or a newly created subscription.

Success means the user can select a team for a project and launch an agent with the intended configuration. Show verified login status separately from saved configuration, and preserve unfinished setup for later.

## Entry points and navigation

- Offer setup from Welcome for new installations. Wait for the runtime inventory before deciding whether this is a new installation; existing users keep their normal window restoration and receive a manual setup entry point.
- Expose the same wizard through Settings → Teams → Add Team. Preserve direct editing of existing teams.
- Offer Resume Setup when a draft exists. A dismissed wizard does not repeatedly interrupt normal use.
- Use Back, Continue, and Save and Finish Later. Persist drafts after meaningful edits. Going back preserves choices; changing a source or destination invalidates the associated copy preview and verification.
- Show step titles and per-team progress. Missing CLIs or one failed login do not prevent configuring another agent.

## User flow

### 1. Choose agents

Select Codex, Claude Code, or both. Discover executables using Chauffeur's existing login-environment behavior and allow choosing a custom executable. Show installed/missing states. For a missing CLI, offer official installation guidance and Recheck; installing software automatically is outside this wizard's scope.

### 2. Understand accounts

Ask each selected agent: One account, Multiple accounts, or Not sure. Explain: “Teams let you choose which account and settings to use for each project.” Not sure reveals examples such as Personal and Work without forcing multiple configurations. One account remains eligible for separate team settings.

### 3. Name teams

Offer editable Personal and Work examples without creating both automatically. A single-account fast path proposes one Personal team using the current configuration. Users may add or remove draft teams and choose agents per team.

Team names remain display names. Generate filesystem-safe slugs independently, show the destination before creation, and validate empty names and slug collisions. Renaming a saved team does not rename its configuration directories.

### 4. Connect configurations

For each team/agent pair, offer Use my current configuration, Choose an existing folder, and Create a separate configuration. For multiple accounts, explicitly ask whether separate folders already exist and route to selection or creation. Allow different answers per team and agent.

Discover the standard home directories, explicit configured paths, and immediate home-directory candidates matching `.claude-*`, `.codex-*`, `.claudewho-*`, and `.codexwho-*`. Discovery is bounded and does not recursively search the disk. Show paths and let users confirm assignments; names do not prove account identity.

Current configuration resolves the effective agent directory, including relevant environment overrides, and displays that path. Save an explicit resolved path so later shell changes do not silently change a wizard-created team's selection.

Sharing a canonical directory is allowed. Label it “Shared with Personal,” for example, and explain that login and setting changes affect every team using it. Reuse one verification result per executable/agent/directory combination during setup. Users may omit an agent from a team.

### 5. Copy settings into a new configuration

Default the editable source to `~/.claude` or `~/.codex`, and the destination to `~/.claude-<team>` or `~/.codex-<team>`. Allow another source or Start fresh. Missing default sources lead to Start fresh or Choose folder.

Use “Copy settings” in the UI. Show selectable categories with item counts and a preview of the affected files. Only offer categories supported by the agent's migration adapter.

| Category | Default |
| --- | --- |
| Preferences and instructions | Selected |
| Skills, prompts, rules, and reusable agent definitions | Selected when present |
| Plugins, MCP connections, and hooks | Unselected, explicit choice |
| Project history and conversations | Unselected; allow project selection where supported |
| Credentials and login sessions | Excluded, not selectable |

Categories must map to parsed content as well as files: a settings file can mix preferences, hooks, connections, and credentials. Never blindly copy that whole file under Preferences. Exclude known credential fields, authentication files, credential-store material, caches, locks, and transient runtime state. If a configuration format cannot be parsed safely, skip that file with a visible explanation; do not claim arbitrary secret detection.

Treat the local claudewho and codexwho implementations as behavioral references, not runtime dependencies. Their default directory names differ from this design. Preserve useful handling such as Claude plugin metadata path repair. Rewrite only recognized source-root references in supported metadata, not arbitrary strings in user content. Preview skipped or unsupported items.

Reject source/destination equality, nested destinations, unwritable destinations, and existing destination collisions. An existing destination offers Use existing folder or Choose another destination; this flow does not merge into an unrelated directory. Resolve path aliases and symlinks before these checks. Internal copied links may be remapped to their copied targets; external or broken symlinks are skipped and reported rather than creating unannounced shared state.

Create in a private staging directory beside the destination, validate the result, then publish without replacing an existing destination. Keep a manifest of wizard-owned operations for recovery. Source files remain untouched. Retrying must not duplicate teams or overwrite files changed since creation.

### 6. Sign in and verify

After creating a configuration, advance directly to its agent login. Existing configurations are checked first and only prompt for login when needed. Run one interactive login at a time, clearly labeled with team, agent, and target directory. Use the resolved executable and exact target environment for both login and verification; inherited authentication overrides must not cause verification of a different identity.

Login runs in a dedicated embedded terminal through a runtime-owned setup process. It does not create a project conversation or count as a normal agent work session. Preserve required interactivity and browser authentication. Closing the wizard detaches the UI; explicit Cancel stops that login process. A runtime restart marks an interrupted login as retryable.

Track Not checked, Signing in, Verifying, Connected, Sign-in required, Unable to verify, and Failed. Connected requires affirmative evidence from a supported agent authentication-status interface in the target context. Credential-file presence, browser closure, or login-process exit alone is insufficient. A status result is not a guarantee of quota or model access, and verification does not send a billable prompt.

Show account identity, organization, and authentication method when the interface exposes them. Let the user confirm the intended account or retry login if it is wrong. Do not infer a provider organization from the Chauffeur team name. If identity is unavailable, say so instead of inventing one. Existing API-key/provider configurations may be used; creating or purchasing provider accounts is outside scope.

Authentication adapters own version/capability detection, login invocation, status parsing, and actionable errors. The implementation plan must establish the exact supported CLI commands and credential-backend isolation behavior from installed CLI help/source and official documentation before coding adapters. Unsupported versions produce Unable to verify with manual instructions and Recheck, never Connected. Do not silently fall back to a global credential context.

### 7. Finish

Show every team with its agents, configuration paths, sharing labels, and login results. Choose the default team and offer Open your first project with that team preselected. Ready configurations can be used while other logins remain pending. “Setup saved — sign-in pending” remains distinct from fully connected setup.

## Architecture and persistence

Keep the new classes in dedicated physical `Onboarding` directories that appear as folders/groups in Xcode: `Sources/ChauffeurApp/Onboarding` for wizard views and presentation state, `Sources/ChauffeurCore/Onboarding` for setup records and contracts, and `Sources/ChauffeurRuntimeKit/Onboarding` for the coordinator and agent adapters. Mirror this grouping in the relevant test targets. Preserve current target ownership and the Swift package boundary; do not collect cross-target files into one target. Generate the Xcode project through the existing XcodeGen setup rather than hand-editing generated project files. Existing entry-point files receive only the integration changes needed to present or dispatch onboarding.

Keep SwiftUI responsible for presentation and draft editing. Add an onboarding coordinator to ChauffeurRuntimeKit for discovery, preview, copy, login operations, and resume. Use separate migration and authentication adapters per agent so filesystem rules and CLI compatibility do not grow inside views or RuntimeCoordinator dispatch methods.

Add versioned Codable setup records in ChauffeurCore and persist them through the runtime's single-writer FileStore boundary. Records contain draft/team IDs, agent selections, explicit source and destination paths, selected categories, operation IDs, created-directory manifests, progress, and redacted verification summaries. They contain no tokens or credential contents. Setup state stays local to the Mac; adding remote onboarding APIs is outside scope.

Represent final teams with the existing `PresetSet.configurationDirectories`. Shared configurations use equal canonical paths; no account registry is required. Reuse existing base presets. A team selecting fewer agents uses existing custom-agent selection with independent copies of the selected presets; do not mutate global base presets to implement that choice.

Persist each successful configuration independently. Assign stable team IDs before side effects and use operation IDs to reconcile a crash between directory publication, team saving, and draft progress updates. Preserve FileStore's revision checks when an existing team changes concurrently. Recheck directory and authentication state on resume rather than trusting an old Connected label indefinitely.

Use existing IPC and terminal infrastructure where it supports this contract, but keep setup processes separate from conversation/session records. Noninteractive probes use bounded timeouts and output limits. Login output and verification errors must not leak tokens into persistent diagnostics.

Update Welcome, Settings, and project-creation handoff. Update README, app help, and manual language that currently requires users to create folders and sign in outside Chauffeur.

## Failure and recovery behavior

- Persist successful pairs even if another copy or login fails; retry only the failed operation.
- Keep incomplete staging separate from usable destinations. On resume, reconcile the operation manifest before cleanup or retry.
- Discarding a draft does not delete a published configuration or existing team. Clean only wizard-owned unpublished staging; show the locations of already-created folders.
- Concurrent windows share one active setup draft/operation for a target. Serialize mutations and reject stale updates instead of launching duplicate copies or logins.
- If the runtime is unavailable, retain UI input and present reconnect/retry. No UI-owned filesystem mutation bypasses runtime ownership.

## Validation and acceptance

Use temporary directories, fake executable adapters, and redacted fixtures for automated checks; never run test logins against personal accounts.

1. One-account onboarding uses an existing configuration, creates one usable team, and opens project creation with that team selected.
2. Separate Claude accounts and shared Codex configuration produce correct mappings and visible sharing labels.
3. Existing claudewho/codexwho folders can be selected without copying or modifying them.
4. New folders use the agreed names; copying respects selected categories, excludes credentials, repairs supported plugin paths, and leaves source contents unchanged.
5. Path aliases, collisions, nested paths, unsupported formats, and symlinks produce the specified outcomes without overwrite or hidden sharing.
6. Each login and status probe receives the intended executable and environment. Wrong browser identity is visible when available. Stale files, failed exits, unknown versions, and probe timeouts cannot produce false Connected results.
7. Save and Finish Later, app closure, runtime interruption, and failure between publication and team save all resume without duplicate teams or repeated destructive work.
8. Keyboard navigation, checkbox labels, errors, and progress work with accessibility APIs. Existing users retain window restoration and direct team editing.
9. Run the repository's relevant core/runtime tests and native UI checks, plus a manual smoke test of each supported agent's isolated login using designated test configurations.

## Scope boundary

This change covers local onboarding, adding teams, selective configuration copying, login assistance, verification, and resumption. It does not manage subscriptions, create provider accounts, install CLIs automatically, synchronize configuration changes between directories, generate shell wrappers, modify global shell startup files, or add remote onboarding.
