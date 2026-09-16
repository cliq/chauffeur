#!/usr/bin/env python3
"""Verify actual Notification Center delivery and a cold notification click.

Uses the default service and its existing, most recently updated session. Requires
notifications already enabled/authorized, no live sessions and a read session in
an active project. Closes that project window, quits the UI, restarts only the
notification helper, and clicks a real test notification. Leaves the project
open. Does not reset data, unregister the service or change OS preferences.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

repository = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--use-default-service', action='store_true', required=True)
parser.add_argument('--app', type=Path, default=repository / 'build/Build/Products/Debug/Chauffeur Debug.app')
parser.add_argument('--artifacts', type=Path, default=repository / '.local/notification-native-repeat')
args = parser.parse_args()
os.umask(0o077)
app = args.app.resolve()
artifacts = args.artifacts.resolve()
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
artifacts.chmod(0o700)
(artifacts / 'summary.json').unlink(missing_ok=True)
helper = repository / '.build/app-accessibility-probe'
subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(helper)], check=True)


def wait_for(operation, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = operation()
        if result:
            return result
        time.sleep(0.2)
    raise AssertionError('Timed out: ' + description)


def call(method, params=None):
    result = subprocess.run([str(app / 'Contents/MacOS/chauffeurctl'), 'request', method,
                             json.dumps(params or {})], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def pids(executable):
    result = subprocess.run(['pgrep', '-f', '^' + re.escape(str(executable)) + '( |$)'], capture_output=True, text=True)
    assert result.returncode in (0, 1), result.stderr
    return [int(pid) for pid in result.stdout.split()]


def one_pid(executable):
    found = pids(executable)
    assert len(found) <= 1, 'Multiple instances of the same executable'
    return found[0] if found else None


def ax(pid, operation='inspect', **fields):
    result = json.loads(subprocess.run([str(helper)], input=json.dumps({'pid': pid, 'operation': operation, **fields}),
                                      capture_output=True, text=True, check=True).stdout)
    if operation != 'inspect':
        assert result.get('performed'), result
    return result


def window(snapshot):
    return next(record['value'] for record in snapshot['store']['windows'] if record['value']['id'] == project['id'])


def unchanged(snapshot):
    assert snapshot['sessions'] == before['sessions'], 'Session records changed'
    assert snapshot['messages'] == before['messages'], 'Messages changed'
    assert snapshot['health']['runtimeID'] == before['health']['runtimeID'], 'Runtime restarted'


before = call('snapshot')
assert before['health']['liveSessions'] == 0, 'Stop live sessions before this focused check'
status = call('notificationStatus')
assert status['enabled'] and status['helperConnected'] and status['authorization'] in ('authorized', 'provisional'), 'Enable/allow notifications first'
projects = {record['value']['id']: record['value'] for record in before['store']['projects'] if not record['value']['archived']}
candidates = [session for session in before['sessions'] if session['projectID'] in projects]
assert candidates, 'An existing session in an active project is required'
session = max(candidates, key=lambda record: record['updatedAt'])
assert not session.get('unread', False), 'Read the latest session before this check'
project = projects[session['projectID']]
app_executable = app / 'Contents/MacOS/Chauffeur'
notification_executable = app / 'Contents/Library/ChauffeurNotifications.app/Contents/MacOS/ChauffeurNotifications'
notification_center_executable = Path('/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter')
control_center_executable = Path('/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter')
(artifacts / 'before-launch.private.json').write_text(json.dumps(before))

subprocess.run(['/usr/bin/open', str(app)], check=True)
pid = wait_for(lambda: one_pid(app_executable), 'app launch')
wait_for(lambda: any(c['role'] == 'AXWindow' for c in ax(pid)), 'app window')
ax(pid, 'press', title='Settings…', role='AXMenuItem', includeMenus=True)
wait_for(lambda: any(c['role'] == 'AXButton' and 'Runtime' in (c['label'], c['title']) for c in ax(pid)), 'Settings tabs')
ax(pid, 'press', title='Runtime')
wait_for(lambda: any(c['identifier'] == 'notifications.test' and c['enabled'] for c in ax(pid)), 'enabled test button')
# Launching an updated bundle can legitimately refresh its registered runtime.
# Establish continuity after registration, while preserving the prelaunch data check.
ready = call('snapshot')
assert ready['sessions'] == before['sessions'] and ready['messages'] == before['messages'], 'Startup changed session/message records'
startup_refreshed_runtime = ready['health']['runtimeID'] != before['health']['runtimeID']
before = ready
(artifacts / 'before.private.json').write_text(json.dumps(before))
ax(pid, 'press', identifier='notifications.test')
wait_for(lambda: any('Test notification queued.' in c.get('value', '') for c in ax(pid)), 'test feedback')
unchanged(call('snapshot'))

# Closing the target first makes startup restoration unable to satisfy the test.
if any(c['role'] == 'AXWindow' and c['title'] == project['name'] for c in ax(pid)):
    ax(pid, 'closeWindow', title=project['name'], role='AXWindow')
wait_for(lambda: not window(call('snapshot'))['wasOpen'], 'project closed on disk')
ax(pid, 'press', title='Quit Chauffeur', role='AXMenuItem', includeMenus=True)
wait_for(lambda: not one_pid(app_executable), 'UI quit')

old_helper = one_pid(notification_executable)
assert old_helper, 'Current bundle notification helper is not running'
os.kill(old_helper, signal.SIGKILL)
new_helper = wait_for(lambda: (pid if (pid := one_pid(notification_executable)) and pid != old_helper else None), 'helper recovery', timeout=40)
wait_for(lambda: call('notificationStatus')['helperConnected'], 'helper connected')
assert call('notificationStatus')['authorization'] == status['authorization']
call('testNotification', {'sessionID': session['id']})

body = 'This is a test notification. Click to open this session.'


def test_control():
    pid = one_pid(notification_center_executable)
    if not pid:
        return None
    matches = [c for c in ax(pid) if c['role'] == 'AXGroup'
               and 'Chauffeur Notifications' in c['label'] and body in c['label']
               and project['name'] in c['label'] and session['title'] in c['label']]
    assert len(matches) <= 1, 'Ambiguous test notification'
    return (pid, matches[0]) if matches else None


# Banners may be hidden by existing Focus/OS preferences; Notification Center
# provides a real delivered notification without changing those preferences.
time.sleep(3)
target = test_control()
if not target:
    cc = one_pid(control_center_executable)
    assert cc, 'Control Center is unavailable'
    ax(cc, 'press', identifier='com.apple.menuextra.clock', includeMenus=True)
    target = wait_for(test_control, 'test notification in Notification Center')
assert not one_pid(app_executable), 'UI unexpectedly running before click'
assert not window(call('snapshot'))['wasOpen'], 'Project unexpectedly open before click'
(artifacts / 'notification-control.private.json').write_text(json.dumps(target[1]))
ax(target[0], 'press', identifier=target[1]['identifier'])
pid = wait_for(lambda: one_pid(app_executable), 'notification cold launch')
wait_for(lambda: any(c['role'] == 'AXWindow' and c['title'] == project['name'] for c in ax(pid)), 'project window')
wait_for(lambda: not any(c['role'] == 'AXWindow' and c['title'].startswith('Welcome to Chauffeur') for c in ax(pid)), 'Welcome dismissed after routing')
after = wait_for(lambda: (snapshot if window(snapshot := call('snapshot'))['wasOpen']
                         and window(snapshot).get('selectedSessionID') == session['id'] else None), 'session selected')
unchanged(after)
(artifacts / 'after.private.json').write_text(json.dumps(after))
report = {'nativeTestButton': True, 'helperRecoveredWithUIQuit': new_helper != old_helper,
          'startupRefreshedRuntime': startup_refreshed_runtime,
          'authorizationPreserved': True, 'notificationCenterDelivered': True,
          'nativeNotificationClick': True, 'coldLaunch': True, 'previouslyClosedProjectOpened': True,
          'welcomeDismissed': True,
          'correctSessionSelected': True, 'sessionRecordsUnchanged': True,
          'messageRecordsUnchanged': True, 'runtimeUnchanged': True}
(artifacts / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
