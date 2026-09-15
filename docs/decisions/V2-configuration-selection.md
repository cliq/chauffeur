# V2 — configuration selection

Status: environment/path fixtures and real Codex profile checks passed; Claude
and full account-display acceptance remain open.

## Decision

Build each child environment separately from the login environment. Strip provider authentication/routing variables, inherited Codex/Claude identity, tmux identity, and shell/loader injection variables. Set only the selected CLI directory and Chauffeur session values for that child. Never mutate the app's global environment or create a native configuration directory.

Reject missing/inaccessible configuration or working directories before spawning. Resolve executable symlinks (including Homebrew installations) and canonicalize filesystem aliases with `realpath`, including `/var` versus `/private/var`. Arguments are a validated array; managed profile, directory, resume and MCP options cannot be overridden by freeform arguments.

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
Both clones now report signed in; credential values were omitted from output.
The application itself does not copy credentials. Skill installation is a
separate explicit action that changes only namespaced guidance files.
See Claude's [credential storage documentation](https://code.claude.com/docs/en/authentication#credential-management)
for its macOS Keychain and private-file fallback routes.

Native account/usage display, authenticated Claude sessions and provider-specific
settings remain acceptance gates. A directory label alone is not evidence of an
authenticated account. The default Codex launch route now has real credential
and scoped-stop evidence; alternate daemon/remote routes are not claimed.
