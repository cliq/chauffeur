# V2 — configuration selection

Status: environment/path fixture checks passed; real-account checks open.

## Decision

Build each child environment separately from the login environment. Strip provider authentication/routing variables, inherited Codex/Claude identity, tmux identity, and shell/loader injection variables. Set only the selected CLI directory and Chauffeur session values for that child. Never mutate the app's global environment or create a native configuration directory.

Reject missing/inaccessible configuration or working directories before spawning. Resolve executable symlinks (including Homebrew installations) and canonicalize filesystem aliases with `realpath`, including `/var` versus `/private/var`. Arguments are a validated array; managed profile, directory, resume and MCP options cannot be overridden by freeform arguments.

The private one-shot exec handoff is created with mode 0600 under the runtime directory, consumed and deleted by `chauffeurctl internal-exec`, and never returned by diagnostics. The ledger stores only a hash of session credentials.

## Evidence

`FoundationTests` covers simultaneous child environments, inherited authentication variables, invalid directory failure, symlink/duplicate paths, and managed argument conflicts. `runtime_smoke.py` launches three fixture processes sharing one preset directory and verifies distinct session credentials and the absence of an inherited fake API key.

Installed help was checked on 2026-09-15: Codex 0.154.0 supports `-C`, `--add-dir`, explicit `resume <id>`, launch config overrides, and redacted `doctor --json`. Claude Code 2.1.272 supports `--add-dir`, `--session-id`, `--resume`, `--settings`, and `--mcp-config`.

## Remaining gate evidence

Two existing configuration directories per CLI, with intended account labels, are needed for the PRD account-isolation scenario. No credentials were copied or real profiles modified. macOS Keychain behavior and provider-specific settings remain to be validated. A directory label alone is not evidence of an authenticated account.

Codex's shared app-server behavior must also be resolved with V3: a daemon may retain its own launch environment after a TUI client exits. Per-TUI environment filtering alone must not be treated as proving backend isolation or scoped stop behavior.
