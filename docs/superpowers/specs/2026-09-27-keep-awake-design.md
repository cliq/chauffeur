# Keep Mac awake

## Intent

Keep the host Mac available while Chauffeur agents work, with a configurable
grace period for agents waiting for input. Let users start or cancel a timed
keep-awake period from macOS and iOS. The background runtime owns this behavior
so closing either app does not end it.

The user requested automatic behavior configurable in settings, manual durations
from both apps, and exclusion of agents waiting longer than a configurable number
of minutes. Proposed defaults: automatic behavior off, waiting grace 30 minutes.

## Behavior

- Automatic mode counts agent sessions only, never ordinary shell terminals.
- Starting and running agents qualify. Agents doing reported background work
  qualify; a coordinator waiting for workers relies on those workers qualifying.
- Agents waiting for input or with a finished turn qualify until their waiting
  grace expires. Moving between these waiting states does not renew the grace.
- A reported return to active work clears the waiting deadline. The next waiting
  period receives a new grace period.
- Unknown activity receives only the bounded grace period, not indefinite
  protection. Providers without lifecycle reporting therefore cannot promise
  indefinite automatic protection; manual timers remain available.
- Exited, failed, interrupted, removed, and explicitly closed sessions do not count.
- Any qualifying agent is sufficient. One expired waiting agent does not affect
  another active agent.
- The waiting limit accepts whole minutes from 1 to 1,440. Changing it immediately
  recalculates eligibility from the original waiting start time.
- Manual controls offer 1, 2, 4, and 8 hours, plus custom hours from 0.25 to 24.
  Starting a timer sets its end time relative to now, replacing an existing timer.
  Cancel affects only the manual timer, not automatic protection.
- Either automatic eligibility or an unexpired manual timer requests protection.
  Turning off automatic mode does not cancel a timer. Expiry releases protection
  only when no automatic reason remains. Releasing protection allows normal
  system sleep policy; it does not force the Mac to sleep.
- Settings and absolute manual expiry persist across runtime restarts. An expired
  timer is never restarted. Waiting timestamps also survive restarts; restarting
  must not grant already-idle sessions a fresh grace period.

## Implementation approach

Use a runtime-owned manager with a pure policy evaluator, an injectable clock,
and an injectable power-assertion driver. The production driver holds one IOKit
PreventUserIdleSystemSleep assertion while protection is requested. This leaves
display sleep available and does not override explicit sleep or lid-close policy.
Release the assertion on shutdown; the OS also releases it on process termination.

Alternatives are a runtime-owned caffeinate subprocess (adds child-process
lifecycle management) or an app-owned assertion (ends when the app closes).
The native runtime assertion fits the existing background-service architecture.

Persist keep-awake settings, manual expiry, and per-session waiting timestamps in
a dedicated runtime state file with atomic writes. Keep policy bookkeeping apart
from Session.updatedAt: unrelated metadata, unread state, output redraws, repeated
waiting notifications, and polling must not renew a waiting grace period.
Prune records for closed or removed sessions. On first adoption of a legacy
waiting/unknown session, use its existing updatedAt as a conservative baseline.
Startup reconciliation must preserve any existing waiting timestamp when it
marks an adopted session's activity unknown.

Evaluate after session lifecycle changes, settings or timer commands, and on the
runtime's existing periodic reconciliation tick. Expiry must run even without an
app or connected remote client and even if terminal inventory fails. Allow at
most one reconciliation interval of expiry latency. Serialize state mutations in
the runtime; schedule assertion work without adding suspension races to session
persistence. Retry assertion failures on later ticks without log flooding.

Expose effective status separately from requested policy: settings, manual end
time, qualifying-agent count, whether an assertion is held, and any actionable
error. Never display protection as active when assertion acquisition failed.
Persistence failures fail the mutation and leave the previous saved policy in
effect. Driver failures retain the requested policy for retry and are visible.

## Interfaces and UI

Add local IPC methods for reading status, changing automatic settings, starting a
timer, and cancelling it. Add matching authenticated remote operations and a
keep-awake capability in the host handshake. Validate settings and timer expiry on the host;
reject non-finite, more-than-24-hour, and malformed values. Timed requests carry an
absolute end time so retrying the same request does not extend it. The UI enforces
the 0.25-hour minimum when starting a timer; the host accepts shorter remaining
times because an absolute-expiry retry may arrive near expiry. Expired requests
are no-ops and do not overwrite a newer timer.

Add an optional status field to remote inventory, omitted when a peer lacks the
capability. Older hosts leave the new controls unavailable; older clients can
continue using inventory and terminals. Do not send new event variants to clients
that cannot decode them. Refresh status through existing inventory updates and
after mutations; each client derives its displayed countdown from the host expiry.

macOS Settings > General gains a Keep Awake section with the automatic toggle,
"Stop counting waiting agents after … minutes", status, duration controls, and
Cancel Timer. iOS gains a gear button in the host connection row on Sessions,
opening Settings with the same settings, status, and timer controls. Disconnect
is the final action in its own section, styled as destructive.
Both edit the connected Mac's shared policy, not per-device preferences.

Disable remote mutations while disconnected and identify cached status as stale.
Do not claim a disconnected Mac is currently protected. Explain in the controls
that the display may sleep and automatic protection excludes long-waiting agents.
Cancelling a timer while automatic protection remains should display that reason.

## Verification

Use an injected clock and fake assertion driver to test active/waiting transitions,
timeout boundaries, changes to the configured limit, repeated waiting events,
unrelated updates, unknown activity, shells, background work, multiple agents,
manual-only protection, overlapping reasons, cancellation, expiry, failed assertion
creation/release, persistence failure, and restart recovery without extending time.

Exercise authenticated remote operations, invalid inputs, older-peer compatibility,
and status propagation. Run relevant runtime/client/protocol tests and the full
Swift package suite. Build both native apps. Validate the actual assertion with
pmset during a short manual smoke test and confirm it is released after cancellation.
Use temporary runtime state for automated tests. Device installation, version bumps,
merging, and publishing are separate from implementation validation.
