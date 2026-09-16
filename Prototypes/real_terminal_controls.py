#!/usr/bin/env python3
"""Real CLI terminal controls through macOS with an authorized profile clone.

Contacts the selected provider for two text-only turns in a temporary repository.
Uses an isolated signed Debug app and runtime; no default service or Release writes.
"""
import argparse
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
os.umask(0o077)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kind', choices=['codex', 'claude'], required=True)
parser.add_argument('--profile', type=Path, required=True)
parser.add_argument('--basic', action='store_true')
options = parser.parse_args()
profile = options.profile.resolve(strict=True)
executable = shutil.which(options.kind)
assert executable and profile.is_dir()
artifacts = repository / '.local' / ('terminal-native-' + options.kind)
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
for name in ['summary.json', 'failed-controls.private.json', 'failed.png']:
    (artifacts / name).unlink(missing_ok=True)
accessibility_helper = repository / '.build/app-accessibility-probe'
subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(accessibility_helper)], check=True)

def uid():
    return str(uuid.uuid4()).upper()

def wait_for(probe, description, timeout=30):
    deadline = time.monotonic() + timeout
    printed = 0
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = probe()
            if result:
                return result
        except (OSError, ValueError, KeyError) as error:
            last_error = error
        if time.monotonic() - printed > 10:
            print('Waiting:', description, flush=True); printed = time.monotonic()
        time.sleep(0.2)
    raise AssertionError('Timed out: ' + description) from last_error

with tempfile.TemporaryDirectory(prefix='chauffeur-real-terminal-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur.app', app, symlinks=True)
    identifier = 'dev.chauffeur.real-terminal-probe.' + uuid.uuid4().hex
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
    runtime_log = (artifacts / 'runtime.private.log').open('w')
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
            connection.settimeout(40); connection.connect(socket_path)
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

    session = None
    window_id = None
    trust_prompts = 0

    def current():
        return next(item for item in call('snapshot')['sessions'] if item['id'] == session['id'])

    def screen():
        value = control(terminal_id)
        text = value['value'] if value else ''
        (artifacts / 'terminal.private.txt').write_text(text)
        return text

    def ready():
        global trust_prompts
        assert current()['state'] not in ('failed', 'exited', 'interrupted'), 'CLI exited before prompt'
        text = screen()
        compact = ''.join(text.split())
        if ''.join(str(repo).split()) in compact:
            if options.kind == 'codex' and 'Do you trust' in text and 'Yes, continue' in text:
                trust_prompts += 1
                (artifacts / 'trust-prompt.private.txt').write_text(text)
                ax('key', terminal_id, keyCode=36); return False
            if options.kind == 'claude' and 'Yes, I trust this folder' in text:
                if '❯ No, exit' in text:
                    ax('key', terminal_id, keyCode=125)
                elif '❯ Yes, I trust this folder' in text:
                    trust_prompts += 1
                    (artifacts / 'trust-prompt.private.txt').write_text(text)
                    ax('key', terminal_id, keyCode=36)
                else:
                    raise AssertionError('Unexpected trust selection; no input sent')
                return False
        if options.kind == 'codex':
            return 'Ask Codex to do anything' in text and 'loading' not in text and 'Do you trust' not in text
        return bool(re.search(r'^❯\s*(Try |$)', text, re.M)) and 'connecting' not in text.lower() and 'Yes, I trust' not in text

    def completed(marker):
        text = screen()
        answer = re.search(r'^\s*[●•⏺]?\s*' + re.escape(marker) + r'\s*$', text, re.M)
        return bool(answer) and (options.basic or current()['state'] == 'turnFinished')

    def open_app(previous_pid=None):
        global app_pid, window_id
        subprocess.run([str(binary_dir / 'chauffeur-launcher'), str(repo)], capture_output=True, check=True)
        value = wait_for(lambda: (s if (s := state())['ready'] and s['online'] and s['processID'] != previous_pid else None), 'native project window')
        app_pid = value['processID']
        windows = json.loads(subprocess.check_output(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], text=True))
        window_id = max(windows['visibleWindows'], key=lambda w: w['bounds']['Width'])['id']

    def search_reply(marker, name):
        ax('key', terminal_id, keyCode=3, modifiers=['command'])
        history_id = 'history-' + session_id
        wait_for(lambda: control(history_id), 'native history')
        wait_for(lambda: any(c['placeholder'] == 'Find' for c in controls()), 'history Find field')
        ax('typeText', placeholder='Find', value=marker)
        wait_for(lambda: control(history_id)['selectedText'] == marker, 'Unicode provider reply in history')
        assert ax('copy', history_id)['text'] == marker
        screenshot(name)
        ax('press', title='Done')
        wait_for(lambda: state()['sheetWindow'] is None, 'history dismissed')

    try:
        wait_for(lambda: call('status'), 'runtime ready')
        repo = root / 'native terminal repository'; repo.mkdir()
        def git(*arguments):
            subprocess.run(['/usr/bin/git', '-C', str(repo), '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *arguments], check=True, capture_output=True)
        git('init', '-b', 'main')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'Fixture')
        set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
        project_name = options.kind.capitalize() + ' Native Terminal Check'
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Native terminal check', 'revision': 1, 'archived': False}})
        arguments = ['-a', 'on-request', '-s', 'workspace-write'] if options.kind == 'codex' else ['--permission-mode', 'manual', '--tools', '']
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Authorized private profile', 'kind': options.kind,
            'executable': executable, 'configurationDirectory': str(profile), 'arguments': arguments, 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': project_name, 'presetSetID': set_id,
            'folders': [{'id': folder_id, 'name': 'Temporary repository', 'selectedPath': str(repo), 'canonicalPath': str(repo), 'availability': 'available', 'registered': True}],
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id, 'folderID': folder_id,
            'additionalFolderIDs': [], 'title': 'Native terminal check', 'allowSharedCheckout': False,
            'coordinationEnabled': not options.basic, 'retryKey': uid()})
        session_id = session['id']; terminal_id = 'terminal-' + session_id
        call('saveWindow', {'record': {'id': project_id, 'tabs': [session_id], 'selectedSessionID': session_id, 'sidebarVisible': True, 'wasOpen': True}})
        open_app()
        wait_for(ready, 'CLI native prompt', 90)
        (artifacts / 'controls.private.json').write_text(json.dumps(controls(), indent=2))
        first_suffix = uuid.uuid4().hex[:6]
        marker = 'NATIVE_READY_café_日本語_' + first_suffix
        prompt = 'Do not use tools or read files. Reply only with NATIVE_READY_café_日本語_ immediately followed by ' + first_suffix
        assert marker not in prompt
        ax('insertText', terminal_id, value=prompt)
        wait_for(lambda: first_suffix in screen() and 'café_日本語_' in screen(), 'Unicode prompt displayed')
        ax('key', terminal_id, keyCode=36)
        wait_for(lambda: completed(marker), 'first provider reply', 180)
        screenshot('first-response')
        search_reply(marker, 'first-reply-history')
        ax('key', terminal_id, keyCode=0, modifiers=['command'])
        wait_for(lambda: marker in control(terminal_id)['selectedText'], 'native CLI output selection')
        assert marker in ax('copy', terminal_id)['text']
        second_suffix = uuid.uuid4().hex[:6]
        second_marker = 'NATIVE_AFTER_café_日本語_' + second_suffix
        draft = 'Do not use tools or read files. Reply only with NATIVE_AFTER_café_日本語_ immediately followed by ' + second_suffix
        assert second_marker not in draft
        ax('paste', terminal_id, value=draft)
        wait_for(lambda: second_suffix in screen() and 'NATIVE_AFTER' in screen(), 'native pasted draft')
        before = call('terminalSnapshot', {'sessionID': session_id})
        ax('resize', title=project_name, role='AXWindow', width=1050.0, height=710.0)
        def resized():
            value = call('terminalSnapshot', {'sessionID': session_id})
            (artifacts / 'resize.json').write_text(json.dumps({'before': [before['columns'], before['rows']], 'after': [value['columns'], value['rows']]}))
            return (value['columns'], value['rows']) != (before['columns'], before['rows']) and second_suffix in screen()
        wait_for(resized, 'native resize preserves draft')
        screenshot('resized-draft')
        first_process = current()['processID']
        runtime_id = call('snapshot')['health']['runtimeID']
        for force in [False, True]:
            old_pid = app_pid
            if force:
                os.kill(old_pid, 9)
            else:
                ax('key', terminal_id, keyCode=12, modifiers=['command'])
            wait_for(lambda: subprocess.run(['/bin/kill', '-0', str(old_pid)], capture_output=True).returncode != 0, 'UI quit')
            assert current()['processID'] == first_process and current()['state'] not in ('exited', 'failed', 'interrupted')
            assert call('snapshot')['health']['runtimeID'] == runtime_id
            open_app(previous_pid=old_pid)
            wait_for(lambda: second_suffix in screen() and 'NATIVE_AFTER' in screen(), 'native draft restored after ' + ('force quit' if force else 'normal quit'))
        ax('key', terminal_id, keyCode=36)
        wait_for(lambda: completed(second_marker), 'reply after both UI relaunches', 180)
        search_reply(second_marker, 'second-reply-history')
        report = {'result': 'pass', 'kind': options.kind, 'version': session['launch']['executableVersion'],
            'basicTerminalMode': options.basic, 'nativeTrustPromptsHandled': trust_prompts, 'nativeUnicodePrompt': True,
            'nativeSelectionAndCopy': True, 'nativeClipboardPaste': True, 'nativeResize': True,
            'normalAndForceQuitRetainDraftAndProcess': True, 'secondReplyAfterRelaunch': True,
            'unicodeProviderRepliesSearchableAndCopyable': True, 'profileUnchanged': current()['launch'] == session['launch'],
            'providerTurns': 2}
        assert report['profileUnchanged']
        (artifacts / 'summary.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
    except BaseException:
        try:
            (artifacts / 'failed-controls.private.json').write_text(json.dumps(controls(), indent=2))
            if window_id: screenshot('failed')
        except Exception:
            pass
        raise
    finally:
        if app_pid:
            subprocess.run(['/bin/kill', '-TERM', str(app_pid)], capture_output=True)
        if session:
            try: call('stop', {'sessionID': session['id'], 'force': True})
            except Exception: pass
        subprocess.run(['tmux', '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired: runtime.kill(); runtime.wait(timeout=5)
        runtime_log.close()
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
