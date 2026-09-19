# Onboarding implementation validation

Implemented on `feat/onboarding-wizard` using Agent Team and the implementation
progress panel, without the Superpowers execution workflow, as requested.

The native wizard lives in `Sources/ChauffeurApp/Onboarding`, with records in
`Sources/ChauffeurCore/Onboarding` and services in
`Sources/ChauffeurRuntimeKit/Onboarding`. XcodeGen creates the corresponding
groups; the latter two folders are in the local Swift package.

## Checks performed

- `swift test --no-parallel`: 341 tests in 67 suites passed during the review-fix
  pass. After the final review refinements, all 36 tests in the six affected
  discovery, authentication, migration, and review-regression suites passed.
- `make build`: Debug app built, signed, and signature verified.
- `python3 Prototypes/onboarding_smoke.py`: passed against the final runtime.
  Covers shared Codex and separate Claude configurations, selective copying,
  unchanged source digests, fake login, service restart/resume, repeated finish,
  project creation, and an actual fixture session using the Work configuration.
- Independent review: actionable findings resolved and re-reviewed. Regression
  coverage includes nested credential exclusion, hidden plugin manifests,
  executable script permissions, expected-version crash recovery, and agent
  subsets when multiple teams introduce new presets.
- `git diff --check`: passed.

The parallel package run exposed a remote-connection timing failure in an
existing test. Its isolated retry passed, and the complete serial run passed.

## Review fixes (19 September)

- Discovery persists stable commands or configured symlink paths. Resolution
  happens at use time; created drafts can repair vanished legacy version paths.
  Finish does not reuse a version-pinned preset for a stable command.
- Nested reusable assets named `auth`, `debug`, `logs`, and lockfiles are retained.
  Known credential files remain excluded, with separate transient-file warnings.
- Settings sanitization distinguishes identifiers, environment-variable names,
  ordinary environment values, and credential fields. Removed nested paths appear
  in preview warnings without their values. Tests cover identifier collisions,
  API/access keys, auth headers, query keys, and unsupported nested hooks.
- Finish validates every requested team and agent before saving anything; missing
  folders or executables produce actionable errors instead of omitted teams.
- Claude MCP connections are extracted from the profile's `.claude.json`, or the
  bounded default-home sibling, without copying account fields. Codex marketplace
  configuration is included with plugins. Unsupported Codex `hooks.json` is warned.
- Absolute source-folder references are disclosed rather than rewritten. Source
  scripts are not automatically copied. The ownership marker remains for recovery.
- Codex API-key status suffixes are accepted without persisting their contents;
  Claude status permits stderr notices while retaining JSON and directory checks.
  Login starts only when the user explicitly chooses Sign in.

Compared against the local `codexwho/bin/codexwho` and
`claudewho/bin/claudewho` migration implementations. Unlike their verbatim copies,
Chauffeur intentionally sanitizes configuration and reports omissions. Independent
static re-review found no remaining actionable findings after the refinements.

## Checks that could not execute

The native UI test target builds. Two runs of
`make test-ui XCODEBUILD_ARGS='-only-testing:ChauffeurAppUITests/OnboardingWizardTests'`
stopped before any test method with `Timed out while enabling automation mode`.
The separate native accessibility probe reported `Accessibility access is
unavailable`; no permissions were changed. The UI tests cover returning to Welcome after finishing setup,
saved draft resumption, and returning-user window restoration, but their runtime
assertions remain unverified on this machine.

Installed Codex 0.155.0 and Claude Code 2.1.278 were checked only with help and
unauthenticated status in fresh isolated profiles. Automated login tests use fake
CLIs. Real browser OAuth and different-account acceptance require designated
test accounts and remain unverified; no personal accounts were used.
The isolated logged-out probe supports separation when reading credentials; it
does not verify that real browser login writes a separate Claude Keychain item.
Codex status does not expose account identity. Provider status commands may create
metadata in the selected configuration directory.
