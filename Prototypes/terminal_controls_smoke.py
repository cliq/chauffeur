#!/usr/bin/env python3
"""Native terminal input, clipboard and history controls through macOS.

Uses an isolated signed Debug copy, temporary folder and two fixture CLI sessions.
No provider accounts, default runtime, real repositories or Release app writes.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

repository = Path(__file__).resolve().parents[1]
artifacts = repository / '.build/terminal-controls-artifacts'
artifacts.mkdir(exist_ok=True)
for name in ['summary.json', 'failed-controls.json', 'failed.png']:
    (artifacts / name).unlink(missing_ok=True)
accessibility_helper = repository / '.build/app-accessibility-probe'
subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(accessibility_helper)], check=True)

def uid():
    return str(uuid.uuid4()).upper()

def wait_for(probe, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = probe()
            if result:
                return result
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.1)
    raise AssertionError('Timed out: ' + description)

with tempfile.TemporaryDirectory(prefix='chauffeur-terminal-controls-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur Debug.app', app, symlinks=True)
    identifier = 'dev.chauffeur.terminal-controls-probe.' + uuid.uuid4().hex
    socket_path = str(root / 'runtime/runtime.sock')
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIdentifier'] = identifier
    info['LSEnvironment'] = {'CHAUFFEUR_SOCKET': socket_path, 'CHAUFFEUR_QUICK_SESSION_PROBE_DIR': str(root)}
    info_path.write_bytes(plistlib.dumps(info))
    signing = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
    identities = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]+) "Developer ID Application: Leonardo Lobato \([^"]+"', signing.stdout, re.M)
    assert len(identities) == 1
    with (artifacts / 'sign.log').open('w') as log:
        subprocess.run(['codesign', '--force', '--sign', identities[0], '--preserve-metadata=entitlements,flags,runtime', str(app)], stdout=log, stderr=log, check=True)
    binary_dir = app / 'Contents/MacOS'
    runtime_log = (artifacts / 'runtime.log').open('w')
    runtime = subprocess.Popen([str(binary_dir / 'ChauffeurRuntime'), '--data-dir', str(root)], stdout=runtime_log, stderr=runtime_log)
    app_pid = None

    def exact(connection, count):
        data = bytearray()
        while len(data) < count:
            part = connection.recv(count - len(data))
            assert part, 'Socket closed'
            data.extend(part)
        return data

    def call(method, params=None, expect_error=False):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(20); connection.connect(socket_path)
            data = json.dumps({'version': 1, 'id': uid(), 'method': method, 'params': params or {}}).encode()
            connection.sendall(struct.pack('!I', len(data)) + data)
            count, = struct.unpack('!I', exact(connection, 4))
            assert count <= 8 * 1024 * 1024
            response = json.loads(exact(connection, count))
            if expect_error:
                assert response.get('error'), 'Expected an error'
                return response['error']
            assert not response.get('error'), response.get('error')
            return response.get('result')

    def state():
        return json.loads((root / 'quick-state.json').read_text())

    def command(action, **fields):
        identifier = uid()
        temporary = root / 'quick-command.tmp'
        temporary.write_text(json.dumps({'id': identifier, 'action': action, **fields}))
        temporary.replace(root / 'quick-command.json')
        return wait_for(lambda: (s if (s := state()).get('commandID') == identifier else None), 'command completed')

    def accessibility(operation, **fields):
        result = subprocess.run([str(accessibility_helper)], input=json.dumps({'pid': app_pid, 'operation': operation, **fields}), text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def controls():
        return accessibility('inspect')

    def control(identifier):
        return next((item for item in controls() if item['identifier'] == identifier), None)

    def ax(operation, identifier=None, **fields):
        if identifier is not None:
            fields['identifier'] = identifier
        result = accessibility(operation, **fields)
        assert not result.get('error') and result.get('performed'), result
        return result

    def screenshot(name):
        # State publication precedes SwiftUI's next native layout/display pass.
        time.sleep(0.5)
        window = state()['sheetWindow'] or window_id
        assert window
        subprocess.run(['/usr/sbin/screencapture', '-x', '-l', str(window), str(artifacts / (name + '.png'))], check=True)

    try:
        wait_for(lambda: call('status'), 'runtime ready')
        repo = root / 'terminal repository'; repo.mkdir()
        input_directory = root / 'inputs'; input_directory.mkdir()
        cli = root / 'keyboard-cli'
        cli.write_text('#!' + sys.executable + '\nimport os, runpy\n'
            + 'os.environ["CHAUFFEUR_FIXTURE_INPUT"] = ' + repr(str(input_directory) + '/') + ' + os.environ["CHAUFFEUR_SESSION_ID"] + ".bin"\n'
            + 'os.environ["CHAUFFEUR_FIXTURE_STABLE_SCREEN"] = "1"\n'
            + 'runpy.run_path(' + repr(str(repository / 'Prototypes/fake_cli.py')) + ', run_name="__main__")\n')
        cli.chmod(0o700)
        set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Controls fixture', 'revision': 1, 'archived': False}})
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Fixture agent', 'kind': 'codex', 'executable': str(cli), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Terminal Controls Fixture', 'presetSetID': set_id,
            'folders': [{'id': folder_id, 'name': 'Terminal repository', 'selectedPath': str(repo), 'canonicalPath': str(repo), 'availability': 'available', 'registered': True}],
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id,
            'folderID': folder_id, 'additionalFolderIDs': [], 'title': 'Keyboard fixture',
            'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
        session_id = session['id']
        input_log = input_directory / (session_id + '.bin')
        second = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id,
            'folderID': folder_id, 'additionalFolderIDs': [], 'title': 'Second keyboard fixture',
            'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
        second_log = input_directory / (second['id'] + '.bin')
        call('saveWindow', {'record': {'id': project_id, 'selectedSessionID': session_id, 'selectedFolderID': folder_id,
            'selectedWorktreePath': str(repo), 'sidebarMode': 'repositories', 'sidebarVisible': True, 'wasOpen': True}})
        subprocess.run([str(binary_dir / 'chauffeur-launcher'), str(repo)], capture_output=True, check=True)
        ready = wait_for(lambda: (s if (s := state())['online'] and s['ready'] else None), 'project window ready')
        app_pid = ready['processID']
        windows = json.loads(subprocess.check_output(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], text=True))
        window_id = max(windows['visibleWindows'], key=lambda w: w['bounds']['Width'])['id']
        (artifacts / 'controls.json').write_text(json.dumps(controls(), indent=2))
        terminal_id = 'terminal-' + session_id
        wait_for(lambda: (c if (c := control(terminal_id)) and 'Chauffeur fixture' in c['value'] else None), 'terminal exposed to accessibility')
        assert control(terminal_id)['role'] == 'AXTextArea' and control(terminal_id)['enabled']
        assert 'Sparse cells:     gap' in control(terminal_id)['value']
        assert '\0' not in control(terminal_id)['value'], 'Blank terminal cells must be exposed as spaces'
        text = 'native café 日本語 --literal'
        ax('insertText', terminal_id, value=text)
        wait_for(lambda: input_log.exists() and text.encode() in input_log.read_bytes(), 'native Unicode input')
        ax('key', terminal_id, keyCode=11, modifiers=['control'])
        wait_for(lambda: b'\x02' in input_log.read_bytes(), 'Control-B passed to the CLI')
        ax('key', terminal_id, keyCode=0, modifiers=['command'])
        wait_for(lambda: 'Chauffeur fixture' in control(terminal_id)['selectedText'], 'native Select All')
        copied = ax('copy', terminal_id)['text']
        assert 'Chauffeur fixture' in copied and text in copied
        pasted = 'clipboard café 日本語'
        ax('paste', terminal_id, value=pasted)
        wait_for(lambda: b'\x1b[200~' + pasted.encode() + b'\x1b[201~' in input_log.read_bytes(), 'bracketed Unicode paste')
        before_history = input_log.read_bytes()
        ax('key', terminal_id, keyCode=3, modifiers=['command'])
        history_id = 'history-' + session_id
        wait_for(lambda: control(history_id), 'Command-F opened history')
        wait_for(lambda: any(c['placeholder'] == 'Find' for c in controls()), 'native Find field')
        ax('typeText', placeholder='Find', value='fixture-history-249')
        wait_for(lambda: control(history_id)['selectedText'] == 'fixture-history-249', 'normal-buffer history match')
        assert ax('copy', history_id)['text'] == 'fixture-history-249'
        screenshot('history-search')
        ax('typeText', placeholder='Find', value='native café 日本語')
        wait_for(lambda: control(history_id)['selectedText'] == 'native café 日本語', 'Unicode match in captured active screen')
        ax('insertText', history_id, value='history-must-not-send')
        ax('paste', history_id, value='history-paste-must-not-send')
        assert input_log.read_bytes() == before_history, 'Read-only history sent input'
        ax('press', title='Done')
        wait_for(lambda: state()['sheetWindow'] is None, 'history closed')
        ax('key', terminal_id, keyCode=30, modifiers=['command', 'shift'])
        wait_for(lambda: state()['selectedSession'] == second['id'], 'next session shortcut')
        second_terminal = 'terminal-' + second['id']
        wait_for(lambda: (c if (c := control(second_terminal)) and 'Chauffeur fixture' in c['value'] else None), 'second terminal attached')
        ax('insertText', second_terminal, value='second terminal input')
        wait_for(lambda: second_log.exists() and second_log.read_bytes() == b'second terminal input', 'input routed to second session')
        ax('key', second_terminal, keyCode=33, modifiers=['command', 'shift'])
        wait_for(lambda: state()['selectedSession'] == session_id, 'previous session shortcut')
        def window_state():
            return next(w['value'] for w in call('snapshot')['store']['windows'] if w['value']['id'] == project_id)
        # Session switching stays inside the selected checkout; both fixtures share it.
        wait_for(lambda: state()['selectedWorktree'] == str(repo) and state()['selectedFolder'] == folder_id, 'main checkout selected')
        wait_for(lambda: window_state().get('selectedWorktreePath') == str(repo) and window_state().get('sidebarMode') == 'repositories', 'checkout selection persisted')
        assert control('session.card.' + session_id) and control('session.card.' + second['id']), 'both session cards in the checkout strip'
        assert not window_state().get('tabs') and window_state().get('splitSessionID') is None, 'legacy tab fields must stay empty'
        assert input_log.read_bytes() == before_history
        old_pid = app_pid
        ax('key', terminal_id, keyCode=12, modifiers=['command'])
        wait_for(lambda: subprocess.run(['/bin/kill', '-0', str(old_pid)], capture_output=True).returncode != 0, 'Command-Q quit UI')
        assert input_log.read_bytes() == before_history
        retained = next(s for s in call('snapshot')['sessions'] if s['id'] == session_id)
        assert retained['processID'] == session['processID'] and retained['state'] == 'activityUnknown'
        subprocess.run([str(binary_dir / 'chauffeur-launcher'), str(repo)], capture_output=True, check=True)
        ready = wait_for(lambda: (s if (s := state())['processID'] != old_pid and s['ready'] else None), 'project reopened')
        app_pid = ready['processID']
        wait_for(lambda: (c if (c := control(terminal_id)) and pasted in c['value'] else None), 'unsent input after UI relaunch')
        ax('insertText', terminal_id, value=' after reattach')
        wait_for(lambda: input_log.read_bytes().endswith(b' after reattach'), 'new native input on same process')
        ax('key', terminal_id, keyCode=53)
        wait_for(lambda: input_log.read_bytes().endswith(b'\x1b'), 'Escape passed to CLI')
        ax('key', terminal_id, keyCode=8, modifiers=['control'])
        wait_for(lambda: input_log.read_bytes().endswith(b'\x03'), 'Control-C passed to CLI')
        wait_for(lambda: next(s for s in call('snapshot')['sessions'] if s['id'] == session_id)['state'] == 'exited', 'interrupted fixture exited')
        assert next(s for s in call('snapshot')['sessions'] if s['id'] == second['id'])['state'] == 'activityUnknown'
        report = {'passed': True, 'terminalAccessibility': True, 'nativeUnicodeKeyboardInput': True,
            'controlKeysAndEscapePassedThrough': True, 'nativeSelectAllAndCopy': True, 'bracketedUnicodePaste': True,
            'commandFHistorySearch': True, 'readOnlyHistoryInput': True, 'commandQQuitKeepsAgent': True,
            'sessionSwitchingShortcuts': True, 'splitShortcut': True, 'interruptLeavesOtherSessionRunning': True,
            'relaunchPreservesProcessAndInput': True, 'XCUITest': 'not exercised', 'realCLI': 'not exercised'}
        (artifacts / 'summary.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    except BaseException:
        try:
            (artifacts / 'failed-controls.json').write_text(json.dumps(controls(), indent=2))
            screenshot('failed')
        except Exception:
            pass
        raise
    finally:
        if app_pid:
            subprocess.run(['/bin/kill', '-TERM', str(app_pid)], capture_output=True)
        subprocess.run(['tmux', '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired: runtime.kill(); runtime.wait(timeout=5)
        runtime_log.close()
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
