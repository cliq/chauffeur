# V2 — configuration selection

Status: environment/path fixtures and native two-window Codex/Claude profile
checks pass with the authorized A/B clones. Distinct-Claude-account acceptance
is deferred at the user's request.

## Decision

Build each child environment separately from the login environment. Strip provider authentication/routing variables, inherited Codex/Claude identity, tmux identity, and shell/loader injection variables. Resolve both harness directories from the project team and apply them with Chauffeur session values for that child. Base presets configure commands; independent custom copies can override those commands. Blank team paths use harness defaults. Never mutate the app's global environment or create a native configuration directory.

Reject missing/inaccessible explicitly configured directories for the selected agent harness, and invalid working directories, before spawning. Blank team paths permit the CLI to initialize its default directory. Shells preserve explicit path values even when absent; zsh reapplies them after normal user startup files. Resolve executable symlinks (including Homebrew installations) and canonicalize filesystem aliases with `realpath`, including `/var` versus `/private/var`. Arguments are a validated array; managed profile, directory, resume and MCP options cannot be overridden by freeform arguments.

The private one-shot exec handoff is created with mode 0600 under the runtime directory, consumed and deleted by `chauffeurctl internal-exec`, and never returned by diagnostics. The ledger stores only a hash of session credentials.

## Evidence

`FoundationTests` covers simultaneous child environments, inherited authentication variables, invalid directory failure, symlink/duplicate paths, and managed argument conflicts. `runtime_smoke.py` launches three fixture processes sharing one preset directory and verifies distinct session credentials and the absence of an inherited fake API key.

Installed help was checked on 2026-09-15: Codex 0.154.0 supports `-C`, `--add-dir`, explicit `resume <id>`, launch config overrides, and redacted `doctor --json`. Claude Code 2.1.272 supports `--add-dir`, `--session-id`, `--resume`, `--settings`, and `--mcp-config`.

## Remaining gate evidence

On 2026-09-15 the user authorized private copies of existing Codex/Claude profile
directories for testing. Two clones per CLI were created outside Git, with
symlink targets copied into independent files. The Codex clones report ChatGPT
logins and contain distinct account-context IDs. Three real Codex sessions,
including two sharing one profile, completed authenticated message operations,
explicit resume and runtime restart checks. See [V3](V3-mcp-and-status.md).

Claude's directory copies initially lacked their matching macOS Keychain
credentials. After separate explicit authorization on 2026-09-15, those two
records were copied into private `0600` credential files in the test clones.
Both clones report signed in; credential values were omitted from output. During
native use, Claude migrated profile A's fallback file into the Keychain entry
associated with that clone's configuration path. The original profile's path
and entry remain separate.
The application itself does not copy credentials. Skill installation is a
separate explicit action that changes only namespaced guidance files.
See Claude's [credential storage documentation](https://code.claude.com/docs/en/authentication#credential-management)
for its macOS Keychain and private-file fallback routes.

`Prototypes/real_claude_integration.py` launches three real Claude Code 2.1.272
sessions across the two clones, with two sessions sharing one profile. Native
`/status` shows the expected account, organization, and conversation ID in each
terminal. The probe also reads fixed indicators from its own processes through
Darwin `KERN_PROCARGS2`: the configuration directory matches the selected clone,
and injected invalid `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, and
`OPENAI_API_KEY` values are absent. Raw process environments are never written
or returned by the probe.

Both supplied Claude profiles currently report the same account and
organization. This proves separate configuration-directory selection and
matching native account displays; distinct-Claude-account selection remains
unverified. Six real message operations, scoped stop, explicit resume and
runtime reconnection also pass; see [V3](V3-mcp-and-status.md). Alternate
daemon/remote routes are not claimed.

`Prototypes/native_profile_selection.py` subsequently passes with the signed
Release app, Codex 0.154.0 and Claude Code 2.1.273 in explicit basic-terminal
mode. Each CLI has two simultaneous sessions in separate native project
windows. macOS keyboard input opens each real `/status` display. Its account
email matches the selected clone; Claude's organization and conversation ID
also match native `auth status` diagnostics. Codex `doctor --json` reports the
intended configuration directory, and its two clones have distinct stored
account contexts. Raw JWTs and credentials stay in memory and are never logged.

For all four processes, fixed indicators obtained through `KERN_PROCARGS2`
confirm the exact child configuration directory and absence of the injected
invalid provider/authentication variables. Both basic-mode sessions remain
`Activity unknown` while live. The check sends no model prompts. Private native
display captures and reports are under `.local/profiles-native-{codex,claude}/`.
This covers the current two-window profile/account-display requirement within
the user's existing-profile constraint; it does not claim distinct Claude
accounts or billing/usage isolation.

A third authorized directory contained a file-based login and initially reported
a different account. Its private configuration copy reported signed out after
native startup, so the distinct-account probe stopped before sending any model
task. That clone needs a fresh native sign-in before the account-separation case
can proceed; the cause of its lost login has not been established.

The user chose to continue with the current A/B profiles. The different-account
Claude check remains deferred; no further sign-in changes are being attempted.
