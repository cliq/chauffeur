#!/usr/bin/env python3
"""Real Codex integration with existing private test profiles; contacts the provider.

Use clones with unrelated executable hooks/plugins/MCP servers disabled. This
fixture preserves the supplied configurations and their native model selection.
Only explicit fixture message calls receive one-time native approval.
"""
from datetime import datetime, timezone
import argparse
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
parser.add_argument('--codex', default=shutil.which('codex'))
parser.add_argument('--runtime', type=Path, default=repo / '.build/debug/ChauffeurRuntime')
parser.add_argument('--artifacts', type=Path, default=repo / '.local/real-codex-artifacts')
options = parser.parse_args()
profiles = {'a': options.profile_a.resolve(strict=True), 'b': options.profile_b.resolve(strict=True)}
assert profiles['a'] != profiles['b'] and all((p.is_dir() for p in profiles.values()))
artifacts = options.artifacts.resolve()
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
artifacts.chmod(0o700)
binary = options.runtime.resolve(strict=True)
tmux = shutil.which('tmux')
assert options.codex and tmux, 'Install Codex and tmux first'
approval_tick = lambda: None

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

    def start():
        return subprocess.Popen([str(binary), '--data-dir', str(root)], stdout=log, stderr=log)

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
        # Let Codex finish detecting the pasted burst before Return submits it.
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
            if 'Do you trust' in screen and 'Yes, continue' in screen and (str(checkout.resolve()) in screen):
                subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], 'Enter'], check=True)
                return False
            return 'Ask Codex to do anything' in screen and 'loading' not in screen
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
            if 'Allow the chauffeur MCP server to run tool "chauffeur_send_message"?' not in screen:
                continue
            fields = dict(re.findall('^\\s+(body|recipientID|retryKey): (.+)$', screen, re.M))
            recipient, body = expected
            if fields != {'body': body, 'recipientID': recipient, 'retryKey': body} or '› 1. Allow ' not in screen:
                raise RuntimeError('Unexpected native approval; left unapproved')
            key = (session['id'], body)
            if key in approved_calls:
                continue
            approved_calls.add(key)
            subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), 'send-keys', '-t', session['id'], 'Enter'], check=True)
            print('Approved fixture message once:', body, flush=True)
    approval_tick = approve_fixture_calls

    def message(body):
        return next((m for m in call('snapshot')['messages'] if m['body'] == body), None)

    def completed(session):
        value = next((s for s in call('snapshot')['sessions'] if s['id'] == session['id']))
        return value if value['state'] == 'turnFinished' and value.get('nativeConversationID') else None

    def tree():
        raw = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,stat=,comm='], text=True)
        processes = {int(f[0]): (int(f[1]), int(f[2]), f[3], f[4]) for l in raw.splitlines() if len((f := l.split(None, 4))) == 5}
        owned = set((s['processID'] for s in sessions))
        while True:
            extra = {pid for pid, v in processes.items() if v[0] in owned} - owned
            if not extra:
                break
            owned.update(extra)
        return [(pid, *processes[pid]) for pid in sorted(owned) if pid in processes]
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
            call('savePreset', {'record': {'id': id, 'setID': set_id, 'name': 'Codex ' + suffix.upper(), 'kind': 'codex', 'executable': options.codex, 'configurationDirectory': str(profiles[suffix]), 'arguments': ['-a', 'on-request', '-s', 'read-only'], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Real CLI fixture', 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': 'Empty fixture', 'selectedPath': str(checkout), 'canonicalPath': str(checkout.resolve()), 'availability': 'available', 'registered': True}], 'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        for title, preset in [('Codex A1', presets[0]), ('Codex A2', presets[0]), ('Codex B1', presets[1])]:
            session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset, 'folderID': folder_id, 'additionalFolderIDs': [], 'title': title, 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
            sessions.append(session)
            assert session['launch']['configurationPath'] == str(profiles['b' if title == 'Codex B1' else 'a'])
            ready(session)
        first, second, other = sessions
        for index, session in enumerate(sessions):
            task(session, second['id'], f'profile-check-{index}')
        time.sleep(2)
        print('active process tree', tree(), flush=True)
        for index, session in enumerate(sessions):
            m = wait(lambda: message(f'profile-check-{index}'), label='authenticated message ' + session['title'], timeout=180)
            assert m['senderID'] == session['id'] and m['recipientID'] == second['id']
            result = wait(lambda: completed(session), label='notify hook ' + session['title'], timeout=60)
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
        report = {'result': 'pass', 'CLI': sessions[0]['launch']['executableVersion'], 'profiles': 2, 'sessions': 3, 'sharedProfileCredentials': 'distinct authenticated senders', 'notify': 'native conversation IDs recorded', 'stop': 'peer remains usable', 'resume': 'same recorded conversation; new process and credential', 'runtimeRestart': 'same agent processes; MCP client reconnects'}
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
