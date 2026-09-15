#!/usr/bin/env python3
"""Real CLI checkout recovery with an already-authorized private profile clone.

Contacts the selected provider for two text-only turns. Uses temporary Git repos,
a private runtime/tmux socket, and the clone's existing model/auth configuration.
Does not grant tool approvals, copy credentials, or change the default service.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import uuid

os.umask(0o077)
repository = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kind', choices=['codex', 'claude'], required=True)
parser.add_argument('--profile', type=Path, required=True)
parser.add_argument('--basic', action='store_true', help='Test basic terminal mode without completion hooks (Claude only)')
options = parser.parse_args()
profile = options.profile.resolve(strict=True)
artifacts = repository / '.local' / ('checkout-recovery-' + options.kind)
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
summary = artifacts / 'summary.json'
summary.unlink(missing_ok=True)
binary = repository / '.build/debug/ChauffeurRuntime'
executable, tmux = shutil.which(options.kind), shutil.which('tmux')
assert profile.is_dir() and executable and tmux
assert not options.basic or options.kind == 'claude', 'Codex needs its completion hook to record the native conversation ID'


def uid():
    return str(uuid.uuid4()).upper()


def wait(probe, label, timeout=120):
    deadline, printed = time.monotonic() + timeout, 0
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        if time.monotonic() - printed > 10:
            print('Waiting:', label, flush=True)
            printed = time.monotonic()
        time.sleep(0.2)
    raise AssertionError('Timed out: ' + label)


def git(directory, *arguments):
    subprocess.run(['/usr/bin/git', '-C', str(directory), '-c', 'core.hooksPath=/dev/null',
                    '-c', 'commit.gpgsign=false', *arguments], check=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix='chauffeur-recovery-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    main, extra = root / 'main', root / 'extra'
    for checkout in (main, extra):
        checkout.mkdir()
        git(checkout, 'init', '-q', '-b', 'main')
        git(checkout, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
            'commit', '--allow-empty', '-qm', 'Fixture')
    runtime_log = (artifacts / 'runtime.private.log').open('w')
    runtime = subprocess.Popen([str(binary), '--data-dir', str(root)], stdout=runtime_log, stderr=runtime_log)
    session = None

    def call(method, params=None, expected_error=None):
        def exact(connection, count):
            data = bytearray()
            while len(data) < count:
                chunk = connection.recv(count - len(data))
                assert chunk, 'Socket closed'
                data.extend(chunk)
            return data
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(35)
            connection.connect(str(root / 'runtime/runtime.sock'))
            payload = json.dumps({'version': 1, 'id': uid(), 'method': method, 'params': params or {}}).encode()
            connection.sendall(struct.pack('!I', len(payload)) + payload)
            count, = struct.unpack('!I', exact(connection, 4))
            assert count <= 8 * 1024 * 1024
            response = json.loads(exact(connection, count))
            if expected_error:
                assert response.get('error', {}).get('code') == expected_error, 'Unexpected recovery result'
            else:
                assert not response.get('error'), response.get('error', {}).get('code')
            return response.get('result')

    def current():
        return next(item for item in call('snapshot')['sessions'] if item['id'] == session['id'])

    def capture():
        text = subprocess.check_output([tmux, '-S', str(root / 'runtime/tmux.sock'), 'capture-pane', '-p', '-t', session['id']], text=True)
        (artifacts / 'terminal.private.txt').write_text(text)
        return text

    def key(value):
        subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], value], check=True)

    def prompt(text):
        subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], '-l', '--', text], check=True)
        time.sleep(0.6)
        key('Enter')

    def ready():
        assert current()['state'] not in ('failed', 'exited', 'interrupted'), 'Real CLI exited before prompt'
        screen = capture()
        # Long paths wrap; Codex may ask about the main repository's root.
        compact = ''.join(screen.split())
        if any(str(path) in compact for path in (primary, main, root / 'moved-main')):
            if options.kind == 'codex' and 'Do you trust' in screen and 'Yes, continue' in screen:
                key('Enter')
                return False
            if options.kind == 'claude' and 'Yes, I trust this folder' in screen:
                if '❯ No, exit' in screen:
                    key('Down')
                elif '❯ Yes, I trust this folder' in screen:
                    key('Enter')
                else:
                    raise AssertionError('Unexpected trust dialog; no selection sent')
                return False
        if options.kind == 'codex':
            return 'Ask Codex to do anything' in screen and 'loading' not in screen and 'Do you trust' not in screen
        return bool(re.search(r'^❯\s*(Try |$)', screen, re.M)) and 'connecting' not in screen.lower() and 'Yes, I trust' not in screen

    def completed(marker):
        value = current()
        return value if (options.basic or value['state'] == 'turnFinished') and value.get('nativeConversationID') and re.search(r'^\s*[●•⏺]?\s*' + re.escape(marker) + r'\s*$', capture(), re.M) else None

    def runtime_ready():
        assert runtime.poll() is None, 'Runtime exited before opening its socket'
        return (root / 'runtime/runtime.sock').exists()

    try:
        wait(runtime_ready, 'runtime socket', 20)
        wait(lambda: call('status').get('mcpEndpoint'), 'runtime ready', 20)
        set_id, preset_id, project_id, group_id, folder_id, extra_id = [uid() for _ in range(6)]
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Recovery fixture', 'revision': 1, 'archived': False}})
        arguments = ['-a', 'on-request', '-s', 'workspace-write'] if options.kind == 'codex' else ['--permission-mode', 'manual', '--tools', '']
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Recovery fixture', 'kind': options.kind, 'executable': executable,
            'configurationDirectory': str(profile), 'arguments': arguments, 'integration': 'unverified', 'archived': False}})
        folders = [{'id': identifier, 'name': path.name, 'selectedPath': str(path), 'canonicalPath': str(path), 'availability': 'available', 'registered': True}
                   for identifier, path in [(folder_id, main), (extra_id, extra)]]
        call('saveProject', {'record': {'id': project_id, 'name': 'Recovery fixture', 'presetSetID': set_id, 'folders': folders,
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        tree = call('createWorktree', {'projectID': project_id, 'folderID': folder_id, 'branch': 'fixture/recovery', 'baseRef': 'HEAD'})['value']
        primary = Path(tree['path'])
        session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id, 'folderID': folder_id,
            'additionalFolderIDs': [extra_id], 'worktreeID': tree['id'], 'title': 'Recovery fixture', 'allowSharedCheckout': False,
            'coordinationEnabled': not options.basic, 'retryKey': uid()})
        assert len(session['launch']['checkoutIdentities']) == 2
        wait(ready, 'native prompt')
        token = 'RECOVERY_' + uuid.uuid4().hex[:12].upper()
        prompt('Text-only fixture; do not use tools or read files. Remember the token ' + token + ' in this conversation. Reply with only CHECKOUT_READY.')
        before = wait(lambda: completed('CHECKOUT_READY'), 'first native completion', 180)
        call('removeWorktree', {'worktreeID': tree['id']}, expected_error='active_worktree')
        call('stop', {'sessionID': session['id'], 'force': True})
        ended = current()

        moved = root / 'moved-main'
        main.rename(moved)
        git(moved, 'worktree', 'repair')
        project = next(item for item in call('snapshot')['store']['projects'] if item['value']['id'] == project_id)
        project['value']['folders'][0].update(selectedPath=str(moved), canonicalPath=str(moved))
        call('saveProject', {'record': project['value'], 'version': project['version']})
        call('refreshWorktrees')
        def relinked():
            updated = next(item['value'] for item in call('snapshot')['store']['worktrees'] if item['value']['id'] == tree['id'])
            assert updated['repositoryID'] == tree['repositoryID'], 'Repository identity changed after its move'
            return updated['repositoryPath'] == str(moved)
        # Refresh can join a scan which started before the project was relinked.
        wait(relinked, 'background inventory observes the relinked repository', 30)

        for name, checkout in [('primary', primary), ('additional', extra)]:
            metadata, original = checkout / '.git', root / ('original-' + name)
            metadata.rename(original)
            try:
                git(checkout, 'init', '-q', '-b', 'replacement')
                call('resume', {'sessionID': session['id']}, expected_error='checkout_changed')
                rejected = current()
                assert rejected['launch'] == ended['launch'] and rejected['state'] == ended['state']
            finally:
                if metadata.is_dir():
                    shutil.rmtree(metadata)
                original.rename(metadata)
        resumed = call('resume', {'sessionID': session['id']})
        assert resumed['launch'] == before['launch'] and resumed['nativeConversationID'] == before['nativeConversationID']
        assert resumed['processID'] != before['processID']
        wait(ready, 'resumed native prompt')
        prompt('Without using tools or reading files, reply with only the token I asked you to remember earlier in this conversation.')
        after = wait(lambda: completed(token), 'resumed conversation remembers original token', 180)
        assert after['nativeConversationID'] == before['nativeConversationID']
        call('stop', {'sessionID': session['id'], 'force': True})
        call('removeWorktree', {'worktreeID': tree['id']})
        assert not primary.exists()
        git(moved, 'show-ref', '--verify', 'refs/heads/fixture/recovery')
        report = {'result': 'pass', 'kind': options.kind, 'version': session['launch']['executableVersion'], 'basicTerminalMode': options.basic,
            'mainRepositoryRelocation': True, 'primaryAndAdditionalReplacementRejected': True,
            'restoredCheckoutResumesOriginalConversation': True, 'conversationRecall': True,
            'sameProfileAndLaunchSnapshot': True, 'liveRemovalRejected': True, 'cleanRemovalPreservesBranch': True}
        summary.write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
    except BaseException:
        if session:
            try:
                (artifacts / 'history.private.json').write_text(json.dumps(call('terminalSnapshot', {'sessionID': session['id']}), indent=2))
            except Exception:
                pass
        raise
    finally:
        if session:
            try:
                call('stop', {'sessionID': session['id'], 'force': True})
            except Exception:
                pass
        runtime.terminate()
        try:
            runtime.wait(timeout=10)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        runtime_log.close()
