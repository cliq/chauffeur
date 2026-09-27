# Keep Awake Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and the agent-team skill for the assigned independent components. Track steps here.

**Goal:** Implement automatic and timed Mac keep-awake controls on this branch.
**Architecture:** Runtime-owned policy and native IOKit assertion; portable status and requests; both clients edit the same host state.
**Tech Stack:** Swift, IOKit, SwiftUI, existing local IPC and authenticated remote protocol.
**Spec:** docs/superpowers/specs/2026-09-27-keep-awake-design.md

## Global Constraints
- Automatic off initially; waiting grace 30 minutes, configurable 1–1440 whole minutes.
- Manual timer 0.25–24 hours; presets 1, 2, 4, 8; absolute expiry survives restart.
- Agent waiting timestamps do not reset from metadata, polling, repeated waiting events, or restart.
- Portable modules cannot import ChauffeurCore or IOKit.
- Work on current branch; no merge, push, installation, or version bump in this task.

## Review Focus
- Unknown/adopted sessions must not gain endless fresh idle grace after restarts.
- Cancelling a timer must preserve protection for active agents.
- Failed power assertions must not be shown as successful protection.
- Old peers must keep decoding inventory and using terminals.
- Session persistence is reentrant: power policy must consume current sessions without stale writes.

## Tasks
- [x] Runtime policy and driver: create KeepAwakeManager.swift and KeepAwakeManagerTests.swift. Inject driver and time via explicit now parameters; verify transitions, expiry, multiple reasons, failures and restart with temporary storage. Integrate RuntimeCoordinator persist/start/reconcile and IPC commands; evaluate expiry even on reconciliation failure.
- [x] Portable remote controls: create KeepAwake.swift in RemoteProtocol with KeepAwakeSettings, KeepAwakeStatus, and KeepAwakeTimerRequest. Add getKeepAwake, setKeepAwakeSettings, setKeepAwakeTimer operations and keepAwake result; inventory optional status and capability. Bridge runtime methods and RemoteHostSession methods. Test round trips, legacy decoding, host validation and authorization paths.
- [x] Native UI: Settings General section on macOS; host-row sheet on iOS. Shared portable value types; settings toggle and waiting minutes, presets/custom duration, expiry/cancel, errors and stale status. Both clients refresh after mutations. Build apps.
- [x] Integration: relevant tests followed by full Swift package tests, macOS and iOS simulator builds, native assertion smoke and independent review. Fix actionable findings and report evidence.

## Interfaces
Portable types live in ChauffeurRemoteProtocol (macOS target adds this package product).
`KeepAwakeSettings(automatic: Bool = false, waitingMinutes: Int = 30)`.
`KeepAwakeStatus(settings: KeepAwakeSettings, manualUntil: Date?, qualifyingAgents: Int, assertionHeld: Bool, error: String?)`.
`KeepAwakeTimerRequest(until: Date?)`: nil cancels; host validates absolute end time, finite, no more than 24h in future; UI validates 0.25–24 hours. Already-expired retry is a no-op.
Runtime methods: `keepAwakeStatus() -> KeepAwakeStatus`, `setKeepAwakeSettings(_ settings: KeepAwakeSettings) throws -> KeepAwakeStatus`, `setKeepAwakeTimer(_ request: KeepAwakeTimerRequest) throws -> KeepAwakeStatus` (actor-isolated).
Local IPC methods of the same names: getKeepAwake, setKeepAwakeSettings (params decoded as settings), setKeepAwakeTimer (params decoded as timer request). Snapshot field `keepAwake`.
RemoteHostSession: public methods `setKeepAwakeSettings(_:) async throws`, `setKeepAwakeTimer(until: Date?) async throws`, status through inventory.keepAwake; support through host capability `keepAwake.v1`.

## Execution notes
User explicitly requested implementation on this branch after reviewing the spec. Proceeding with implementation rather than requesting another permission gate; independent components delegated with fixed interfaces. Defaults and boundaries above resolve optional choices.

## Verification ledger
- Runtime tests first failed on missing policy/driver, then passed after implementation.
- Initial focused run: 78 tests; corrected a timestamp fixture to match existing whole-second wire precision.
- Initial full suite: 589 tests passed; signed macOS build and iOS simulator build passed.
- Native assertion smoke uses `pmset -g assertions` to verify actual acquire/release.
- Review finding: partial keep-awake mutation incorrectly cleared global inventory staleness. Added deterministic failing regression, removed partial freshness assignment; 19 client tests passed.
- Review finding: stale restored running record could erase a durable waiting deadline. Added failing restart regression and explicit startup adoption policy; 59 focused runtime/client/remote tests passed including native assertion smoke.
- Independent re-review found no actionable defect in either fix.
- Ruling: timer UI enforces 0.25–24 hours; host validates finite absolute expiry no more than 24 hours away. Positive remaining times below 15 minutes remain valid for retries; expired requests are no-ops. Spec clarified accordingly.
- Final verification: all 591 tests in 111 suites passed, including the native assertion smoke. Rebuilt macOS app passed strict signature verification. Latest iOS simulator build passed after the client fix. `git diff --check` clean. Changes remain on kimi-code as requested.

- iPhone follow-up: host row now opens Settings through a gear button; Disconnect is the final destructive action. Release build installed and launched successfully.
- Keyboard follow-up: added a failing regression for resize during terminal attachment; reconcile the final cell size after attach. All 38 relevant client tests and the signed iOS Release build passed; updated app installed on iPhone 16 Pro.
