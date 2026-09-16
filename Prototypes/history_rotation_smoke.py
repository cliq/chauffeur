#!/usr/bin/env python3
"""Sustained real-tmux history rotation in an isolated runtime, no providers.

One fixture emits 36,000 plain Unicode lines, then 24,000 styled lines. Check
periodic captures without a UI, tmux's line limit, encoded byte limits, unchanged
capture deduplication, runtime restart and durable history after tmux loss.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
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
binary = repository / 'build/Build/Products/Debug/Chauffeur Debug.app/Contents/MacOS/ChauffeurRuntime'
artifacts = repository / '.build/history-rotation-artifacts'
artifacts.mkdir(exist_ok=True)
(artifacts / 'summary.json').unlink(missing_ok=True)
os.umask(0o077)


def uid():
    return str(uuid.uuid4()).upper()


def wait_for(operation, description, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = operation()
            if result:
                return result
        except (OSError, ValueError):
            pass
        time.sleep(0.2)
    raise AssertionError('Timed out: ' + description)


with tempfile.TemporaryDirectory(prefix='chauffeur-history-rotation-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    repo = root / 'repo'; repo.mkdir()
    socket_path = str(root / 'runtime/runtime.sock')
    log = (artifacts / 'runtime.log').open('w')
    runtime = None
    def start_runtime():
        return subprocess.Popen([str(binary), '--data-dir', str(root)], stdout=log, stderr=log)
    def call(method, params=None):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30); connection.connect(socket_path)
            body = json.dumps({'version': 1, 'id': uid(), 'method': method, 'params': params or {}}).encode()
            connection.sendall(struct.pack('!I', len(body)) + body)
            def exact(size):
                result = bytearray()
                while len(result) < size:
                    part = connection.recv(size - len(result))
                    assert part, 'Runtime disconnected'
                    result.extend(part)
                return result
            size, = struct.unpack('!I', exact(4))
            assert size <= 8 * 1024 * 1024
            response = json.loads(exact(size))
            assert not response.get('error'), response.get('error')
            return response['result']
    def emit(until, styled=False):
        temporary = root / 'output-command.tmp'
        temporary.write_text(json.dumps({'until': until, 'styled': styled}))
        temporary.replace(root / 'output-command.json')
    def progress():
        return int((root / 'output-progress').read_text())
    def rows(value):
        return [int(row) for row in re.findall(r'row-(\d{8})', value)]
    cli = root / 'history-cli'
    cli.write_text('#!' + sys.executable + '\n' + '''
import json, os, sys, time
from pathlib import Path
if '--version' in sys.argv:
    print('codex-cli 0.154.0'); raise SystemExit
if '--help' in sys.argv:
    print('Fixture: --add-dir --resume'); raise SystemExit
root = Path(os.environ['CODEX_HOME'])
line = 0
while True:
    config = json.loads((root / 'output-command.json').read_text())
    limit = min(line + (200 if config['styled'] else 100), config['until'])
    while line < limit:
        style = ''.join(('\x1b[32m' if n % 2 else '\x1b[36m') + 'x' for n in range(55)) if config['styled'] else 'plain output'
        print(f'row-{line:08d} café 日本語 ' + style + '\x1b[0m', flush=False)
        line += 1
    sys.stdout.flush()
    temporary = root / 'output-progress.tmp'
    temporary.write_text(str(line)); temporary.replace(root / 'output-progress')
    time.sleep(0.1)
''')
    cli.chmod(0o700)
    emit(0)
    samples = []
    try:
        runtime = start_runtime()
        health = wait_for(lambda: call('status'), 'runtime ready')
        settings = call('snapshot')['settings']
        settings['scrollbackLines'] = 10_000; settings['snapshotBudgetBytes'] = 1_048_576
        call('saveSettings', settings)
        set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'History fixture', 'revision': 1, 'archived': False}})
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'History writer', 'kind': 'codex', 'executable': str(cli), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'History fixture', 'presetSetID': set_id,
            'folders': [{'id': folder_id, 'name': 'Repository', 'selectedPath': str(repo), 'canonicalPath': str(repo), 'availability': 'available', 'registered': True}],
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id, 'folderID': folder_id,
            'additionalFolderIDs': [], 'title': 'Continuous output', 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
        snapshot_file = root / 'runtime/snapshots' / session['id'] / 'latest.json'
        unchanged_file = root / 'unrelated-conversation.json'; unchanged_file.write_text('preserve')
        emit(36_000)
        started = time.monotonic()
        for target in [6_000, 12_000, 18_000, 24_000, 30_000, 36_000]:
            wait_for(lambda: progress() >= target, 'continuous output batch')
            # Read the runtime's periodic archive without requesting a capture.
            saved = wait_for(lambda: (value if snapshot_file.exists()
                             and rows((value := json.loads(snapshot_file.read_text()))['history'] + value['screen'])
                             and max(rows(value['history'] + value['screen'])) >= target - 5_500 else None), 'periodic capture advances')
            ids = rows(saved['history'] + saved['screen'])
            assert saved['processID'] == session['processID']
            assert len(saved['history'].splitlines()) <= 10_000
            assert snapshot_file.stat().st_size <= settings['snapshotBudgetBytes']
            assert '�' not in saved['history'] + saved['screen']
            samples.append({'written': target, 'first': min(ids), 'last': max(ids), 'bytes': snapshot_file.stat().st_size, 'capturedAt': saved['capturedAt']})
        plain = wait_for(lambda: (value if max(rows((value := call('terminalSnapshot', {'sessionID': session['id']}))['screen']), default=-1) == 35_999 else None), 'final plain output reaches tmux')
        assert max(rows(plain['screen'])) == 35_999 and min(rows(plain['history'])) > 20_000
        assert len({sample['capturedAt'] for sample in samples}) >= 5
        print('Plain Unicode output rotated through the 10,000-line limit with periodic captures.', flush=True)
        emit(60_000, styled=True)
        wait_for(lambda: progress() == 60_000, 'styled output completes', timeout=35)
        styled = wait_for(lambda: (value if max(rows((value := call('terminalSnapshot', {'sessionID': session['id']}))['screen']), default=-1) == 59_999 else None), 'final styled output reaches tmux')
        assert max(rows(styled['screen'])) == 59_999
        assert styled['truncated'] and len(styled['history'].splitlines()) < 10_000
        assert '\x1b[' in styled['history'] and '日本語' in styled['history']
        assert snapshot_file.stat().st_size <= settings['snapshotBudgetBytes']
        raw = snapshot_file.read_bytes(); modified = snapshot_file.stat().st_mtime_ns
        assert call('terminalSnapshot', {'sessionID': session['id']}) == styled
        assert snapshot_file.read_bytes() == raw and snapshot_file.stat().st_mtime_ns == modified
        runtime.kill(); runtime.wait(timeout=5); runtime = start_runtime()
        wait_for(lambda: (value if (value := call('status'))['runtimeID'] != health['runtimeID'] else None), 'runtime restart')
        restored = call('terminalSnapshot', {'sessionID': session['id']})
        assert restored == styled, 'Restart changed stable output or its capture timestamp'
        assert call('snapshot')['sessions'][0]['processID'] == session['processID']
        subprocess.run([shutil.which('tmux'), '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], check=True)
        call('reconcile')
        assert call('snapshot')['sessions'][0]['state'] == 'interrupted'
        assert call('terminalSnapshot', {'sessionID': session['id']}) == styled
        assert unchanged_file.read_text() == 'preserve'
        report = {'passed': True, 'linesWritten': 60_000, 'periodicCapturesObserved': len(samples),
                  'elapsedOutputSeconds': round(time.monotonic() - started, 1), 'tmuxLineRotation': True,
                  'unicodeAndANSI': True, 'encodedBytes': len(raw), 'budgetBytes': settings['snapshotBudgetBytes'],
                  'stableCaptureNotRewritten': True, 'runtimeRestartSameProcess': True, 'historySurvivesTmuxLoss': True,
                  'scope': 'one isolated fixture; no workload/performance claim'}
        (artifacts / 'summary.json').write_text(json.dumps(report, indent=2))
        (artifacts / 'samples.json').write_text(json.dumps(samples, indent=2))
        print(json.dumps(report, indent=2))
    finally:
        subprocess.run([shutil.which('tmux'), '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        if runtime and runtime.poll() is None:
            runtime.terminate()
            try: runtime.wait(timeout=10)
            except subprocess.TimeoutExpired: runtime.kill(); runtime.wait(timeout=5)
        log.close()
