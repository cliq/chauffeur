# Session notifications

Notifications are off by default. In **Chauffeur → Settings → Runtime**, enable
**Show session notifications**, then allow **Chauffeur Notifications** in the
macOS permission prompt. If access was denied, change it in System Settings →
Notifications. Focus and other macOS settings can silence alerts.

Alerts include the project and session names, with generic text for input
requests, completed turns, failures, incoming messages, or delegation results.
They omit terminal output, message bodies, task/result content, and credentials.
Project/session names can appear on the lock screen according to macOS settings.

Click an alert to open its project and select its session. Chauffeur clears the
window's search/group filter as needed and adds the session's tab. This works
with closed project windows and a quit app. It does not launch an agent, resume
an execution, or send terminal input. Missing records show an availability error.

## Background operation

The app embeds a signed accessory application, `ChauffeurNotifications.app`.
The default background service starts it through Launch Services after opt-in.
It can receive runtime alerts while Chauffeur itself is closed. Apple documents
that a launch agent cannot directly use standard User Notifications; see
[Apple's launch-agent guidance](https://developer.apple.com/forums/thread/804854).
Standalone/custom-data-directory runtimes report notifications unavailable.

The runtime stores the preference and outbox in its SQLite ledger. Alerts are
queued atomically with the session event or accepted message. The outbox retains
one latest alert per session. Accepted-message retries do not enqueue new alerts;
an old acknowledgement cannot discard a newer alert. The helper uses a stable
notification identifier per session when retrying delivery after a crash.
OS acceptance is not proof that the user saw a banner.

Disabling notifications clears the outbox; the helper removes its pending and
delivered notifications and exits. Re-enabling does not replay the old queue.
The macOS permission grant remains in System Settings. The runtime refreshes the
helper after service/app updates so a click opens the current containing app.
Only project/session UUIDs travel in the navigation URL. The main app validates
their membership against its current store before opening a window.

## Verification and remaining acceptance

- Swift tests cover opt-in, no historical replay, durable coalescing, stale
  acknowledgements, retry identity, group rejection, result-recipient routing,
  bounded display names, and strict navigation URL parsing.
- `Prototypes/native_window_smoke.py` sends real Launch Services URLs into a
  running app and a cold app with all project windows previously closed. The
  selected project/session opens without a duplicate window or new agent process.
- `Prototypes/service_lifetime_smoke.py --use-default-service` starts the signed
  accessory app with the main UI closed and reads actual notification permission
  without requesting access. It requires an empty default store with notifications
  disabled and removes its test service registration afterward.

Actual permission authorization, banner delivery, notification clicks with the
main UI quit, Focus behavior, and enabled-helper recovery/update remain native
acceptance gates. The development Mac currently reports `notDetermined`; the
direct URL tests establish navigation behavior, not Notification Center delivery.
