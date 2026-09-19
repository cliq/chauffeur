# Onboarding implementation validation

Implemented on `feat/onboarding-wizard` using Agent Team and the implementation
progress panel, without the Superpowers execution workflow, as requested.

The native wizard lives in `Sources/ChauffeurApp/Onboarding`, with records in
`Sources/ChauffeurCore/Onboarding` and services in
`Sources/ChauffeurRuntimeKit/Onboarding`. XcodeGen creates the corresponding
groups; the latter two folders are in the local Swift package.

## Checks performed

- `swift test --no-parallel`: 326 tests passed. A subsequent migration regression
  was added; `swift test --filter ConfigurationMigrationTests` passed all 7 tests.
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

## Checks that could not execute

The native UI test target builds. Two runs of
`make test-ui XCODEBUILD_ARGS='-only-testing:ChauffeurAppUITests/OnboardingWizardTests'`
stopped before any test method with `Timed out while enabling automation mode`.
The separate native accessibility probe reported `Accessibility access is
unavailable`; no permissions were changed. The UI tests cover project handoff,
saved draft resumption, and returning-user window restoration, but their runtime
assertions remain unverified on this machine.

Installed Codex 0.155.0 and Claude Code 2.1.278 were checked only with help and
unauthenticated status in fresh isolated profiles. Automated login tests use fake
CLIs. Real browser OAuth and different-account acceptance require designated
test accounts and remain unverified; no personal accounts were used.
