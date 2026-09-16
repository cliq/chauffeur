# Session notifications

Notifications are off by default. In **Chauffeur → Settings → Runtime**, enable
**Show session notifications**, then allow **Chauffeur Notifications** in the
macOS permission prompt. If access was denied, change it in System Settings →
Notifications. Focus and other macOS settings can silence alerts.

Once connected, **Send Test Notification** sends a sample alert for the most
recently updated session in an active project. Create a session first if none
exists. The test does not change its status or send agent input. A queued real
alert takes priority; a test has a separate macOS identifier so it does not
replace a delivered real alert. If no banner appears, open Notification Center
by clicking the date/time in the menu bar and find **Chauffeur Notifications**.

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
  bounded display names, strict navigation URL parsing, and test-alert isolation
  from session/message records and pending real alerts.
- `Prototypes/native_window_smoke.py` sends real Launch Services URLs into a
  running app and a cold app with all project windows previously closed. The
  selected project/session opens without a duplicate window or new agent process.
- `Prototypes/service_lifetime_smoke.py --use-default-service` starts the signed
  accessory app with the main UI closed and reads actual notification permission
  without requesting access. It requires an empty default store with notifications
  disabled and removes its test service registration afterward.

- `Prototypes/notification_native_smoke.py --use-default-service` uses an existing
  read session with no live agents and notifications already enabled/authorized.
  It presses **Send Test Notification** through macOS Accessibility, closes the
  project, quits the UI, kills only the notification helper, waits for recovery,
  and sends a test while the UI is closed. It opens Notification Center and
  presses the actual matching macOS alert. The containing app cold-launches and
  opens the previously closed project with the correct session selected. Session
  and message records and the runtime identity stay unchanged. It does not reset
  the store, unregister the service or change OS permission/Focus settings.

Notification and terminal-folder routes now also dismiss the Welcome window
after their project opens. The native notification check reproduced Welcome
remaining behind the project before this fix and verifies its dismissal.

This native check passes on the development Mac. Updating the registered app
from Release to Debug also replaced the enabled helper while preserving the
macOS authorization grant. Evidence is private under `.local/notification-native/`
and `.local/notification-native-repeat/`. Notification Center delivery and a real
cold-launch click are verified. Transient banner visibility and behavior under
different Focus settings are not established by this check.
