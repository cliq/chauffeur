#!/usr/bin/env python3
"""Real Claude Code integration with existing private test profiles; contacts the provider.

Use clones with unrelated executable hooks/plugins/MCP servers disabled. This
fixture preserves the supplied configurations and their native model selection.
Startup compares each terminal /status view with the selected clone while
injecting invalid inherited provider credentials.
Only explicit fixture message calls receive one-time native approval.
"""
from datetime import datetime, timezone
import argparse
import ctypes
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
os.umask(0o077)
repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--profile-a', type=Path, required=True, help='First existing authenticated private test clone')
parser.add_argument('--profile-b', type=Path, required=True, help='Second existing authenticated private test clone')
parser.add_argument('--claude', default=shutil.which('claude'))
parser.add_argument('--runtime', type=Path, default=repo / '.build/debug/ChauffeurRuntime')
parser.add_argument('--artifacts', type=Path, default=repo / '.local/real-claude-artifacts')
parser.add_argument('--startup-only', action='store_true', help='Check launch and native account selection without an inference prompt')
options = parser.parse_args()
profiles = {'a': options.profile_a.resolve(strict=True), 'b': options.profile_b.resolve(strict=True)}
assert profiles['a'] != profiles['b'] and all((p.is_dir() for p in profiles.values()))
artifacts = options.artifacts.resolve()
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
artifacts.chmod(0o700)
(artifacts / ('startup-summary.json' if options.startup_only else 'summary.json')).unlink(missing_ok=True)
binary = options.runtime.resolve(strict=True)
tmux = shutil.which('tmux')
assert options.claude and tmux, 'Install Claude and tmux first'
approval_tick = lambda: None

def fixture_environment_indicators(pid, profile):
    # Darwin's KERN_PROCARGS2 is inspected only for this fixture's recorded PID.
    # Discard the buffer after projecting these fixed indicators. Never print,
    # write or return the raw process environment or Chauffeur session token.
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t()
    assert libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) == 0, 'Cannot inspect fixture process'
    assert 4 < size.value <= 2 * 1024 * 1024
    buffer = ctypes.create_string_buffer(size.value)
    assert libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) == 0, 'Cannot inspect fixture process'
    raw = buffer.raw[:size.value]
    argc, = struct.unpack_from('=i', raw)
    assert 0 < argc < 4096
    cursor = raw.index(b'\0', 4) + 1  # Executable path, then padding before argv.
    while raw[cursor] == 0:
        cursor += 1
    for _ in range(argc):
        cursor = raw.index(b'\0', cursor) + 1
    entries = raw[cursor:].split(b'\0')
    selected = [entry.split(b'=', 1)[1] for entry in entries if entry.startswith(b'CLAUDE_CONFIG_DIR=')]
    routed = any(entry.startswith(prefix) for entry in entries for prefix in [b'ANTHROPIC_API_KEY=', b'ANTHROPIC_AUTH_TOKEN=', b'OPENAI_API_KEY='])
    return {'configurationPathMatches': selected == [os.fsencode(profile)], 'inheritedProviderCredentialsAbsent': not routed}

def uid():
    return str(uuid.uuid4()).upper()

def wait(probe, predicate=bool, timeout=90, label='condition'):
    deadline = time.monotonic() + timeout
    last_print = 0
    while time.monotonic() < deadline:
        approval_tick()
        try:
            result = probe()
            if predicate(result):
                return result
        except (OSError, ValueError, AssertionError):
            pass
        if time.monotonic() - last_print > 10:
            print('waiting', label, flush=True)
            last_print = time.monotonic()
        time.sleep(0.2)
    raise AssertionError('Timed out: ' + label)

def exact(s, n):
    b = bytearray()
    while len(b) < n:
        v = s.recv(n - len(b))
        assert v, 'connection closed'
        b.extend(v)
    return b
with tempfile.TemporaryDirectory(prefix='chauffeur-real-', dir='/tmp') as directory:
    root = Path(directory)
    checkout = root / 'checkout'
    checkout.mkdir()
    subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
    log = open(artifacts / 'runtime.private.log', 'w')
    runtime = None
    sessions = []
    expected_calls = {}
    approved_calls = set()
    account_contexts = {}

    def start():
        return subprocess.Popen([str(binary), '--data-dir', str(root)], stdout=log, stderr=log, env=dict(os.environ, ANTHROPIC_API_KEY='fixture-key-must-be-filtered', ANTHROPIC_AUTH_TOKEN='fixture-token-must-be-filtered', OPENAI_API_KEY='fixture-key-must-be-filtered'))

    def call(method, params=None):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(30)
            s.connect(str(root / 'runtime/runtime.sock'))
            b = json.dumps({'id': uid(), 'version': 1, 'method': method, 'params': params or {}}).encode()
            s.sendall(struct.pack('!I', len(b)) + b)
            n = struct.unpack('!I', exact(s, 4))[0]
            d = json.loads(exact(s, n))
            assert not d.get('error'), d.get('error')
            return d.get('result')

    def capture(session):
        return subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'capture-pane', '-p', '-t', session['id']], capture_output=True, text=True).stdout

    def keys(session, text, enter=True):
        subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], '-l', '--', text], check=True)
        # Let Claude finish detecting the pasted burst before Return submits it.
        if enter:
            time.sleep(0.6)
        if enter:
            subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], 'Enter'], check=True)

    def ready(session):

        def probe():
            current = next((v for v in call('snapshot')['sessions'] if v['id'] == session['id']))
            if current['state'] in ('failed', 'exited', 'interrupted'):
                try:
                    (artifacts / 'startup-archive.private.json').write_text(json.dumps(call('terminalSnapshot', {'sessionID': session['id']}), indent=2))
                except Exception:
                    pass
                raise RuntimeError('CLI ended before its native prompt: ' + current['state'])
            screen = capture(session)
            (artifacts / 'current.private.txt').write_text(screen)
            if 'trust' in screen.lower() and 'Yes, I trust this folder' in screen and (str(checkout.resolve()) in screen):
                if '❯ No, exit' in screen:
                    subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], 'Down'], check=True)
                elif '❯ Yes, I trust this folder' in screen:
                    subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], 'Enter'], check=True)
                else:
                    raise RuntimeError('Unexpected trust selection; left unchanged')
                return False
            return bool(re.search(r'^❯\s*(Try |$)', screen, re.M)) and 'trust' not in screen.lower() and 'connecting' not in screen.lower()
        wait(probe, label='native prompt ' + session['title'])
        print('native prompt ready', session['title'], flush=True)

    def task(session, recipient, body):
        ready(session)
        expected_calls[session['id']] = (recipient, body)
        prompt = f'Integration fixture. Use only the Chauffeur MCP tools. Call chauffeur_send_message with recipientID {recipient}, body exactly "{body}", and retryKey exactly "{body}". Do not inspect files, run commands, use any other tool, or print credentials. After that call succeeds reply only FIXTURE_DONE.'
        keys(session, prompt)

    def approve_fixture_calls():
        for session in sessions:
            expected = expected_calls.get(session['id'])
            if expected is None:
                continue
            screen = capture(session)
            if 'chauffeur — Chauffeur Send Message Tool: (MCP)' not in screen or 'Do you want to proceed?' not in screen:
                continue
            block = screen.rsplit('chauffeur — Chauffeur Send Message Tool: (MCP)', 1)[1].split('About the chauffeur', 1)[0]
            fields = {key: json.loads(value) for key, value in re.findall(r'^\s+([A-Za-z_][A-Za-z0-9_]*): (.+)$', block, re.M)}
            recipient, body = expected
            if fields != {'body': body, 'recipientID': recipient, 'retryKey': body} or not re.search(r'^\s*❯ 1\. Yes\s*$', screen, re.M):
                raise RuntimeError('Unexpected native approval; left unapproved')
            key = (session['id'], body)
            if key in approved_calls:
                continue
            current = next(item for item in call('snapshot')['sessions'] if item['id'] == session['id'])
            if current['state'] != 'needsAttention':
                return
            approved_calls.add(key)
            subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], 'Enter'], check=True)
            print('Approved fixture message once:', body, flush=True)
    approval_tick = approve_fixture_calls

    def message(body):
        return next((m for m in call('snapshot')['messages'] if m['body'] == body), None)

    def completed(session):
        value = next((s for s in call('snapshot')['sessions'] if s['id'] == session['id']))
        return value if value['state'] == 'turnFinished' and value.get('nativeConversationID') else None

    def account_selection(session, profile):
        prefixes = ('CODEX_', 'CLAUDE_', 'CLAUDECODE', 'OPENAI_', 'ANTHROPIC_', 'CHAUFFEUR_', 'AWS_', 'GOOGLE_', 'VERTEX_', 'BEDROCK_')
        environment = {key: value for key, value in os.environ.items() if not key.startswith(prefixes)}
        environment['CLAUDE_CONFIG_DIR'] = str(profile)
        response = subprocess.run([options.claude, 'auth', 'status', '--json'], cwd=checkout, env=environment, capture_output=True, text=True, timeout=20)
        assert response.returncode == 0, 'Selected test clone is not signed in; sign in to that clone before retrying'
        expected = json.loads(response.stdout)
        assert expected['loggedIn'] and Path(expected['configDirectory']).resolve() == profile
        account_contexts[str(profile)] = (expected.get('email'), expected.get('orgId'))
        indicators = fixture_environment_indicators(session['processID'], profile)
        assert all(indicators.values()), 'Fixture process used the wrong directory or inherited provider credentials'
        keys(session, '/status')
        screen = wait(lambda: capture(session), lambda value: 'Version:' in value and ('Account:' in value or 'Login method:' in value), label='native account status')
        (artifacts / ('status-' + session['title'].replace(' ', '-') + '.private.txt')).write_text(screen)
        compact = ''.join(screen.split())
        assert expected.get('email') and ''.join(expected['email'].split()) in compact, 'Native account email differs from the selected profile'
        assert expected.get('orgName') and ''.join(expected['orgName'].split()) in compact, 'Native organization differs from the selected profile'
        assert session['nativeConversationID'] in screen, 'Native status reports a different conversation'
        print('Native account and process configuration match', session['title'], flush=True)
        subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], 'Escape'], check=True)
        ready(session)

    try:
        runtime = start()
        health = wait(lambda: call('status'), lambda v: v.get('mcpEndpoint'), label='runtime')
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        set_id, project_id, folder_id, group_id = [uid() for _ in range(4)]
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Real CLI fixture', 'revision': 1, 'archived': False}})
        presets = []
        for suffix in ('a', 'b'):
            id = uid()
            presets.append(id)
            call('savePreset', {'record': {'id': id, 'setID': set_id, 'name': 'Claude ' + suffix.upper(), 'kind': 'claude', 'executable': options.claude, 'configurationDirectory': str(profiles[suffix]), 'arguments': ['--permission-mode', 'manual', '--tools', ''], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Real CLI fixture', 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': 'Empty fixture', 'selectedPath': str(checkout), 'canonicalPath': str(checkout.resolve()), 'availability': 'available', 'registered': True}], 'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        for title, preset in [('Claude A1', presets[0]), ('Claude A2', presets[0]), ('Claude B1', presets[1])]:
            session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset, 'folderID': folder_id, 'additionalFolderIDs': [], 'title': title, 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
            sessions.append(session)
            (artifacts / 'live.private.json').write_text(json.dumps({'root':str(root),'runtimePID':runtime.pid,'sessions':sessions},indent=2))
            assert session['launch']['configurationPath'] == str(profiles['b' if title == 'Claude B1' else 'a'])
            ready(session)
            account_selection(session, profiles['b' if title == 'Claude B1' else 'a'])
        if options.startup_only:
            report = {'result': 'pass', 'profiles': 2, 'sessions': 3, 'nativeAccountAndProcessConfiguration': 'matched', 'inheritedProviderCredentials': 'absent', 'distinctAccountContexts': len(set(account_contexts.values())) == 2}
            (artifacts / 'startup-summary.json').write_text(json.dumps(report, indent=2))
            print(json.dumps(report, indent=2), flush=True)
            raise SystemExit(0)
        first, second, other = sessions
        for index, session in enumerate(sessions):
            task(session, second['id'], f'profile-check-{index}')
        time.sleep(2)
        print('Three native sessions submitted bounded fixture tasks', flush=True)
        for index, session in enumerate(sessions):
            m = wait(lambda: message(f'profile-check-{index}'), label='authenticated message ' + session['title'], timeout=180)
            assert m['senderID'] == session['id'] and m['recipientID'] == second['id']
            result = wait(lambda: completed(session), label='completion hook ' + session['title'], timeout=60)
            session['nativeConversationID'] = result['nativeConversationID']
            print('message and native conversation recorded', session['title'], flush=True)
        call('stop', {'sessionID': first['id'], 'force': True})
        task(second, other['id'], 'after-peer-stop')
        assert wait(lambda: message('after-peer-stop'), label='peer remains usable')['senderID'] == second['id']
        resumed = call('resume', {'sessionID': first['id']})
        assert resumed['nativeConversationID'] == first['nativeConversationID']
        assert resumed['processID'] != first['processID']
        first['processID'] = resumed['processID']
        ready(first)
        task(first, second['id'], 'after-explicit-resume')
        assert wait(lambda: message('after-explicit-resume'), label='explicit resume uses session credential')['senderID'] == first['id']
        runtime.kill()
        runtime.wait(timeout=5)
        runtime = start()
        wait(lambda: call('status'), lambda v: v.get('runtimeID') != health['runtimeID'] and v.get('mcpEndpoint'), label='runtime restart')
        task(other, second['id'], 'after-runtime-restart')
        assert wait(lambda: message('after-runtime-restart'), label='real MCP client reconnects')['senderID'] == other['id']
        snapshot = call('snapshot')
        assert {s['processID'] for s in snapshot['sessions']} == {s['processID'] for s in sessions}
        assert snapshot['health']['mcpEndpoint'] == health['mcpEndpoint']
        assert len(snapshot['messages']) == 6
        assert len(approved_calls) == 6
        report = {'result': 'pass', 'CLI': sessions[0]['launch']['executableVersion'], 'profiles': 2, 'sessions': 3, 'nativeAccountAndProcessConfiguration': 'matched', 'inheritedProviderCredentials': 'absent', 'distinctAccountContexts': len(set(account_contexts.values())) == 2, 'sharedProfileCredentials': 'distinct authenticated senders', 'hooks': 'permission attention and completion recorded for each session', 'stop': 'peer remains usable', 'resume': 'same recorded conversation; new process and credential', 'runtimeRestart': 'same agent processes; MCP client reconnects'}
        (artifacts / 'summary.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2), flush=True)
    except Exception:
        for i, session in enumerate(sessions):
            (artifacts / f'terminal-{i}.private.txt').write_text(capture(session))
            try:
                (artifacts / f'history-{i}.private.json').write_text(json.dumps(call('terminalSnapshot', {'sessionID': session['id']}), indent=2))
            except Exception:
                pass
        try:
            (artifacts / 'snapshot.private.json').write_text(json.dumps(call('snapshot'), indent=2))
        except Exception:
            pass
        raise
    finally:
        for session in sessions:
            try:
                call('stop', {'sessionID': session['id'], 'force': True})
            except Exception:
                pass
        if runtime and runtime.poll() is None:
            runtime.terminate()
            try:
                runtime.wait(timeout=5)
            except subprocess.TimeoutExpired:
                runtime.kill()
                runtime.wait(timeout=5)
        subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        log.close()
