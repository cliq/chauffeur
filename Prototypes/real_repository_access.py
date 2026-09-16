#!/usr/bin/env python3
"""Verify real multi-repository tools and private runtime crash recovery.

Contacts one provider for two small turns using an authorized profile clone.
Only temporary Git files are read/written. Uses the signed Release runtime,
an isolated socket/tmux server, and ordinary workspace-scoped permissions.
No default service, original credentials, or user repositories are changed.
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
options = parser.parse_args()
profile = options.profile.resolve(strict=True)
assert profile.is_relative_to(repository / '.local/profile-isolation'), 'Use an authorized private profile clone'
executable, tmux = shutil.which(options.kind), shutil.which('tmux')
assert profile.is_dir() and executable and tmux
binary = repository / 'build/Build/Products/Release/Chauffeur.app/Contents/MacOS/ChauffeurRuntime'
artifacts = repository / '.local' / ('repository-access-' + options.kind)
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
summary = artifacts / 'summary.json'
summary.unlink(missing_ok=True)


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
    return subprocess.check_output(['/usr/bin/git', '-C', str(directory), '-c', 'core.hooksPath=/dev/null',
                                    '-c', 'commit.gpgsign=false', *arguments], stderr=subprocess.DEVNULL, text=True)


with tempfile.TemporaryDirectory(prefix='chauffeur-repositories-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    main, extra = root / 'main repository', root / 'additional repository'
    main_token, extra_token, primary_token = ['FIXTURE_' + uuid.uuid4().hex for _ in range(3)]
    for checkout, token in [(main, main_token), (extra, extra_token)]:
        checkout.mkdir()
        git(checkout, 'init', '-q', '-b', 'main')
        (checkout / 'fixture-input.txt').write_text(token + '\n')
        git(checkout, 'add', 'fixture-input.txt')
        git(checkout, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'Fixture')

    runtime_log = (artifacts / 'runtime.private.log').open('w')
    runtime_arguments = [str(binary), '--data-dir', str(root)]
    runtime = subprocess.Popen(runtime_arguments, stdout=runtime_log, stderr=runtime_log)
    session = None

    def call(method, params=None):
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
            assert not response.get('error'), response.get('error', {}).get('code')
            return response.get('result')

    def current():
        return next(s for s in call('snapshot')['sessions'] if s['id'] == session['id'])

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
        compact = ''.join(screen.split())
        if any(''.join(str(path).split()) in compact for path in (primary, main)):
            if options.kind == 'codex' and 'Do you trust' in screen and 'Yes, continue' in screen:
                key('Enter'); return False
            if options.kind == 'claude' and 'Yes, I trust this folder' in screen:
                if '❯ No, exit' in screen: key('Down')
                elif '❯ Yes, I trust this folder' in screen: key('Enter')
                else: raise AssertionError('Unexpected trust selection')
                return False
        if options.kind == 'codex':
            return 'Ask Codex to do anything' in screen and 'loading' not in screen and 'Do you trust' not in screen
        return bool(re.search(r'^❯\s*(Try |$)', screen, re.M)) and 'connecting' not in screen.lower() and 'Yes, I trust' not in screen

    def completed(marker):
        screen = capture()
        assert current()['state'] not in ('failed', 'exited', 'interrupted'), 'CLI ended during the fixture'
        # Long answers wrap at terminal columns; remove whitespace only. The
        # complete marker is absent from both prompts and input files.
        found = marker in ''.join(screen.split())
        return found and (options.kind == 'claude' or current()['state'] == 'turnFinished')

    def runtime_ready():
        assert runtime.poll() is None, 'Runtime exited before opening its socket'
        try:
            return call('status').get('runtimeID')
        except (ConnectionError, FileNotFoundError):
            return False

    try:
        first_runtime = wait(runtime_ready, 'private Release runtime', 20)
        set_id, preset_id, project_id, group_id, folder_id, extra_id = [uid() for _ in range(6)]
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Repository access fixture', 'revision': 1, 'archived': False}})
        arguments = ['-a', 'on-request', '-s', 'workspace-write'] if options.kind == 'codex' else ['--permission-mode', 'acceptEdits', '--tools', 'Read,Write']
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Access fixture', 'kind': options.kind,
            'executable': executable, 'configurationDirectory': str(profile), 'arguments': arguments,
            'integration': 'unverified', 'archived': False}})
        folders = [{'id': identifier, 'name': path.name, 'selectedPath': str(path), 'canonicalPath': str(path), 'availability': 'available', 'registered': True}
                   for identifier, path in [(folder_id, main), (extra_id, extra)]]
        call('saveProject', {'record': {'id': project_id, 'name': 'Repository access fixture', 'presetSetID': set_id, 'folders': folders,
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        tree = call('createWorktree', {'projectID': project_id, 'folderID': folder_id, 'branch': 'fixture/access', 'baseRef': 'HEAD'})['value']
        other = call('createWorktree', {'projectID': project_id, 'folderID': folder_id, 'branch': 'fixture/control', 'baseRef': 'HEAD'})['value']
        primary, control = Path(tree['path']), Path(other['path'])
        (primary / 'fixture-input.txt').write_text(primary_token + '\n')
        session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id, 'folderID': folder_id,
            'additionalFolderIDs': [extra_id], 'worktreeID': tree['id'], 'title': 'Repository access fixture',
            'allowSharedCheckout': False, 'coordinationEnabled': options.kind == 'codex', 'retryKey': uid()})
        assert session['launch']['workingDirectory'] == str(primary)
        assert session['launch']['additionalPaths'] == [str(extra)]
        assert len(session['launch']['checkoutIdentities']) == 2
        wait(ready, 'real CLI prompt')
        marker = 'READ_RESULT:' + primary_token + ':' + extra_token
        task = ('This is an authorized temporary filesystem test. Read only fixture-input.txt in your current working directory '
                'and ' + str(extra / 'fixture-input.txt') + '. Do not change files or use unrelated tools. '
                'Reply with exactly READ_RESULT: followed by the first file token, a colon, then the second file token, all on one line.')
        assert marker not in task
        prompt(task)
        wait(lambda: completed(marker), 'actual reads from primary worktree and additional repository', 180)
        before = current()
        (artifacts / 'before.private.json').write_text(json.dumps(before, indent=2))
        (artifacts / 'read-terminal.private.txt').write_text(capture())
        print('Real file reads passed; terminating only the private runtime', flush=True)

        runtime.kill()
        runtime.wait(timeout=10)
        os.kill(before['processID'], 0)
        runtime = subprocess.Popen(runtime_arguments, stdout=runtime_log, stderr=runtime_log)
        wait(lambda: (identifier if (identifier := runtime_ready()) and identifier != first_runtime else None), 'replacement runtime', 25)
        restored = wait(lambda: (s if (s := current())['state'] not in ('starting', 'interrupted') else None), 'same real CLI reattached', 25)
        assert restored['processID'] == before['processID']
        assert restored['terminalIdentity'] == before['terminalIdentity']
        assert restored['launch'] == before['launch']
        assert restored.get('nativeConversationID') == before.get('nativeConversationID')
        prompt('Continue the same authorized filesystem test. Use the two tokens you read in the previous turn. '
               'Write the first token, followed by a newline, to result.txt in your current working directory. '
               'Write the second token, followed by a newline, to ' + str(extra / 'result.txt') + '. '
               'Change no other files and use no unrelated tools. Reply with exactly WRITE_RESULT: followed by the '
               'first token, a colon, and the second token, all on one line.')
        wait(lambda: completed('WRITE_RESULT:' + primary_token + ':' + extra_token), 'real writes after runtime crash recovery', 180)
        assert (primary / 'result.txt').read_text() == primary_token + '\n'
        assert (extra / 'result.txt').read_text() == extra_token + '\n'
        assert (main / 'fixture-input.txt').read_text() == main_token + '\n'
        assert (control / 'fixture-input.txt').read_text() == main_token + '\n'
        assert not (main / 'result.txt').exists() and not (control / 'result.txt').exists()
        assert not git(main, 'status', '--porcelain') and not git(control, 'status', '--porcelain')
        assert git(primary, 'status', '--porcelain').splitlines() == [' M fixture-input.txt', '?? result.txt']
        assert git(extra, 'status', '--porcelain').splitlines() == ['?? result.txt']
        after = current()
        assert after['processID'] == before['processID']
        (artifacts / 'after.private.json').write_text(json.dumps(after, indent=2))
        report = {'passed': True, 'kind': options.kind, 'version': session['launch']['executableVersion'],
            'basicTerminalMode': options.kind == 'claude', 'primaryWorktreeAndAdditionalRepositoryReadWrite': True,
            'pathsWithSpaces': True, 'mainCheckoutNotAdded': True, 'mainAndSiblingWorktreeUnchanged': True,
            'runtimeCrashPreservesRealProcess': True, 'sameConversationAfterRecovery': True,
            'sameProfileAndLaunchSnapshot': True, 'providerReplyAndToolsAfterRecovery': True}
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
            try: call('stop', {'sessionID': session['id'], 'force': True})
            except Exception: pass
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        runtime_log.close()
