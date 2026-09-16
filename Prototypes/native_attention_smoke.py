#!/usr/bin/env python3
"""Real CLI approval/completion/exit status through native macOS controls.

Uses an authorized private profile clone and an isolated signed Debug app/runtime.
One model task calls only the read-only Chauffeur discovery tool in a fixture
project. Only that exact native tool request receives one-time approval.
No default runtime, original profiles, OS notification settings or user repos.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid

os.umask(0o077)
repository = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kind', choices=['codex', 'claude'], required=True)
options = parser.parse_args()
profile = (repository / '.local/profile-isolation' / (options.kind + '-a')).resolve(strict=True)
executable = shutil.which(options.kind)
assert executable
artifacts = repository / '.local' / ('attention-native-' + options.kind)
artifacts.mkdir(exist_ok=True, mode=0o700)
(artifacts / 'summary.json').unlink(missing_ok=True)
helper = repository / '.build/app-accessibility-probe'
subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(helper)], check=True)


def uid():
    return str(uuid.uuid4()).upper()


def wait(probe, label, timeout=90):
    deadline, printed = time.monotonic() + timeout, 0
    while time.monotonic() < deadline:
        value = probe()
        if value: return value
        if time.monotonic() - printed > 10:
            print('Waiting:', label, flush=True); printed = time.monotonic()
        time.sleep(.2)
    raise AssertionError('Timed out: ' + label)


with tempfile.TemporaryDirectory(prefix='chauffeur-native-attention-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur Debug.app', app, symlinks=True)
    identifier = 'dev.chauffeur.attention-probe.' + uuid.uuid4().hex
    socket_path = root / 'runtime/runtime.sock'
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info['CFBundleIdentifier'] = identifier
    info['LSEnvironment'] = {'CHAUFFEUR_SOCKET': str(socket_path)}
    plist.write_bytes(plistlib.dumps(info))
    with (artifacts / 'sign.log').open('w') as log:
        subprocess.run(['codesign', '--force', '--sign', 'Developer ID Application: Leonardo Lobato',
                        '--preserve-metadata=entitlements,flags,runtime', str(app)], stdout=log, stderr=log, check=True)
    binaries = app / 'Contents/MacOS'
    runtime_log = (artifacts / 'runtime.private.log').open('w')
    runtime = subprocess.Popen([str(binaries / 'ChauffeurRuntime'), '--data-dir', str(root)], stdout=runtime_log, stderr=runtime_log)
    pid, session = None, None

    def call(method, params=None):
        return json.loads(subprocess.check_output([str(binaries / 'chauffeurctl'), 'request', method,
            json.dumps(params or {}), '--socket', str(socket_path)], text=True))

    def current():
        return next(s for s in call('snapshot')['sessions'] if s['id'] == session['id'])

    def ax(operation='inspect', **fields):
        result = json.loads(subprocess.run([str(helper)], input=json.dumps({'pid': pid, 'operation': operation, **fields}),
                                          capture_output=True, text=True, check=True).stdout)
        if isinstance(result, dict): assert result.get('performed'), result
        return result

    def screen():
        c = next((c for c in ax() if c['identifier'] == terminal_id), None)
        text = c['value'] if c else ''
        (artifacts / 'terminal.private.txt').write_text(text)
        return text

    def label_present(label):
        return any(c['role'] == 'AXStaticText' and c['value'] == label for c in ax())

    def key(code, modifiers=None):
        ax('key', identifier=terminal_id, windowIdentifier='project-' + project_id, keyCode=code, modifiers=modifiers or [])

    def prompt(text):
        ax('insertText', identifier=terminal_id, windowIdentifier='project-' + project_id, value=text)
        time.sleep(.6); key(36)

    def ready():
        assert current()['state'] not in ('failed', 'exited', 'interrupted'), 'CLI ended before prompt'
        text = screen()
        if ''.join(str(checkout).split()) in ''.join(text.split()):
            if options.kind == 'codex' and 'Do you trust' in text and 'Yes, continue' in text:
                key(36); return False
            if options.kind == 'claude' and 'Yes, I trust this folder' in text:
                if '❯ No, exit' in text: key(125)
                elif '❯ Yes, I trust this folder' in text: key(36)
                else: raise AssertionError('Unexpected trust selection')
                return False
        if options.kind == 'codex':
            return 'Ask Codex to do anything' in text and 'loading' not in text and 'Do you trust' not in text
        return bool(re.search(r'^❯\s*(Try |$)', text, re.M)) and 'connecting' not in text.lower() and 'Yes, I trust' not in text

    def approval():
        text = screen()
        if options.kind == 'codex':
            return text if 'Allow the chauffeur MCP server to run tool "chauffeur_discover"?' in text and '› 1. Allow ' in text else None
        return text if 'chauffeur — Chauffeur Discover Tool: (MCP)' in text and 'Do you want to proceed?' in text and re.search(r'^\s*❯ 1\. Yes\s*$', text, re.M) else None

    try:
        wait(socket_path.exists, 'private runtime socket', 20)
        checkout = root / 'repository'; checkout.mkdir()
        subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
        set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Attention fixture', 'revision': 1, 'archived': False}})
        arguments = ['-a', 'on-request', '-s', 'read-only'] if options.kind == 'codex' else ['--permission-mode', 'manual', '--tools', '']
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Attention fixture', 'kind': options.kind,
            'executable': executable, 'configurationDirectory': str(profile), 'arguments': arguments, 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Native Attention', 'presetSetID': set_id,
            'folders': [{'id': folder_id, 'name': 'Fixture repository', 'selectedPath': str(checkout), 'canonicalPath': str(checkout), 'availability': 'available', 'registered': True}],
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id, 'folderID': folder_id,
            'additionalFolderIDs': [], 'title': 'Native attention fixture', 'allowSharedCheckout': False, 'coordinationEnabled': True, 'retryKey': uid()})
        terminal_id = 'terminal-' + session['id']
        call('saveWindow', {'record': {'id': project_id, 'tabs': [session['id']], 'selectedSessionID': session['id'], 'sidebarVisible': True, 'wasOpen': True}})
        subprocess.run([str(binaries / 'chauffeur-launcher'), str(checkout)], capture_output=True, check=True)
        report = json.loads(subprocess.check_output(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], text=True))
        pid = report['pid']
        wait(ready, 'real CLI native prompt')
        suffix = uuid.uuid4().hex[:10].upper()
        marker = 'STATUS_READY_' + suffix
        task = ('Use only the Chauffeur MCP tool chauffeur_discover with an empty argument object. '
                'Do not read files, run commands, send messages, delegate or call any other tool. '
                'After the tool succeeds, reply only STATUS_READY_ immediately followed by ' + suffix + '.')
        assert marker not in task
        prompt(task)
        text = wait(approval, 'exact native discovery approval', 180)
        (artifacts / 'approval.private.txt').write_text(text)
        expected_state = 'needsAttention' if options.kind == 'claude' else 'activityUnknown'
        expected_label = 'Needs attention' if options.kind == 'claude' else 'Activity unknown'
        wait(lambda: current()['state'] == expected_state and label_present(expected_label), 'native approval status')
        (artifacts / 'approval-state.private.json').write_text(json.dumps(current(), indent=2))
        # The discovery tool's schema accepts an empty object and has no writes.
        # Confirm its exact name and one-time selection again before Return.
        assert approval()
        key(36)
        wait(lambda: current()['state'] == 'turnFinished' and marker in ''.join(screen().split()), 'native completion signal and actual reply', 180)
        wait(lambda: label_present('Turn finished'), 'completion label in app')
        finished = current()
        assert finished.get('nativeConversationID')
        assert finished['processID'] == session['processID']
        events = [json.loads(line) for line in (root / 'runtime/logs/runtime.jsonl').read_text().splitlines()]
        events = [event for event in events if event.get('sessionID') == session['id']]
        assert [event['tool'] for event in events if event['event'] == 'toolCalled'] == ['chauffeur_discover']
        if options.kind == 'claude':
            states = [event['state'] for event in events if event['event'] == 'sessionChanged']
            attention = states.index('needsAttention')
            continued = states.index('running', attention + 1)
            assert states.index('turnFinished', continued + 1) > continued
        (artifacts / 'events.private.json').write_text(json.dumps(events, indent=2))
        (artifacts / 'completed.private.json').write_text(json.dumps(finished, indent=2))
        (artifacts / 'completion-terminal.private.txt').write_text(screen())
        print('Native approval, completion hook, and visible labels passed', flush=True)
        if options.kind == 'claude':
            # Claude emits an idle notification after about a minute. Finishing
            # a response and waiting does not constitute blocked user input.
            deadline, printed = time.monotonic() + 70, 0
            while time.monotonic() < deadline:
                assert current()['state'] == 'turnFinished', 'An idle notification incorrectly changed completion to needs attention'
                if time.monotonic() - printed > 15:
                    print('Checking completed state while idle', flush=True); printed = time.monotonic()
                time.sleep(.3)
        prompt('/exit')
        wait(lambda: current()['state'] == 'exited', 'native normal exit', 30)
        wait(lambda: label_present('Exited'), 'ended label in app')
        assert current()['exitStatus'] == 0
        summary = {'passed': True, 'kind': options.kind, 'version': session['launch']['executableVersion'],
            'nativeOneTimeApproval': True, 'approvalState': expected_state,
            'nativeCompletionAndConversationID': True, 'nativeVisibleStatusLabels': True,
            'authenticatedDiscoveryObserved': True, 'toolCompletionClearsAttention': options.kind == 'claude',
            'idleCompletionStaysFinished': options.kind == 'claude', 'nativeNormalExit': True,
            'sameProcessUntilExit': True, 'scope': 'one read-only discovery call; no messages or delegation'}
        (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
    except BaseException:
        if pid:
            try: (artifacts / 'failed-controls.private.json').write_text(json.dumps(ax(), indent=2))
            except Exception: pass
        raise
    finally:
        if pid:
            try: os.kill(pid, 15)
            except ProcessLookupError: pass
        if session:
            try: call('stop', {'sessionID': session['id'], 'force': True})
            except Exception: pass
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        subprocess.run(['tmux', '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        runtime_log.close()
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
