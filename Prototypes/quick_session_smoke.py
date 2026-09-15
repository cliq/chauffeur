#!/usr/bin/env python3
"""Actual new-worktree sheet: invalid branch, failed agent, reuse and launch.

Uses an isolated signed Debug copy, temporary Git repository and a fake CLI.
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
import tempfile
import time
import uuid

repository = Path(__file__).resolve().parents[1]
artifacts = repository / '.build/quick-session-artifacts'
artifacts.mkdir(exist_ok=True)

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

with tempfile.TemporaryDirectory(prefix='chauffeur-quick-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur.app', app, symlinks=True)
    identifier = 'dev.chauffeur.quick-probe.' + uuid.uuid4().hex
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

    def call(method, params=None):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(20); connection.connect(socket_path)
            data = json.dumps({'version': 1, 'id': uid(), 'method': method, 'params': params or {}}).encode()
            connection.sendall(struct.pack('!I', len(data)) + data)
            count, = struct.unpack('!I', exact(connection, 4))
            assert count <= 8 * 1024 * 1024
            response = json.loads(exact(connection, count))
            assert not response.get('error'), response.get('error')
            return response.get('result')

    def state():
        return json.loads((root / 'quick-state.json').read_text())

    def command(action, **fields):
        temporary = root / 'quick-command.tmp'
        temporary.write_text(json.dumps({'action': action, **fields}))
        temporary.replace(root / 'quick-command.json')
        wait_for(lambda: not (root / 'quick-command.json').exists(), 'command consumed')

    def screenshot(name):
        # State publication precedes SwiftUI's next native layout/display pass.
        time.sleep(0.5)
        window = state()['sheetWindow']
        assert window
        subprocess.run(['/usr/sbin/screencapture', '-x', '-l', str(window), str(artifacts / (name + '.png'))], check=True)

    try:
        wait_for(lambda: call('status'), 'runtime ready')
        repo = root / 'repo 日本語'; repo.mkdir()
        for args in [['init', '-b', 'main'], ['config', 'core.hooksPath', '/dev/null'], ['config', 'commit.gpgsign', 'false'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'Initial']]:
            subprocess.run(['/usr/bin/git', '-C', str(repo), *args], capture_output=True, check=True)
        fake = root / 'fake-agent.py'
        fake.write_text('''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
root = Path(__file__).resolve().parent
if '--version' in sys.argv:
    if (root / 'fail-version').exists(): sys.exit(1)
    print('2.1.272 (Claude Code)')
elif '--help' in sys.argv:
    print('--resume --add-dir')
else:
    (root / 'agent-started.json').write_text(json.dumps({'cwd': os.getcwd(), 'args': sys.argv[1:]}))
    print('QUICK SESSION FIXTURE', flush=True)
    while True: time.sleep(0.1)
''')
        fake.chmod(0o700)
        (root / 'fail-version').touch()
        set_id, preset_id, project_id, folder_id = uid(), uid(), uid(), uid()
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Quick fixture', 'revision': 1, 'archived': False}})
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Fixture agent', 'kind': 'claude', 'executable': str(fake), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Quick Session Fixture', 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': repo.name, 'selectedPath': str(repo), 'canonicalPath': str(repo), 'availability': 'available', 'registered': True}], 'groups': [{'id': uid(), 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        subprocess.run([str(binary_dir / 'chauffeur-launcher'), str(repo)], capture_output=True, check=True)
        ready = wait_for(lambda: (s if (s := state())['online'] and s['ready'] else None), 'project window ready')
        app_pid = ready['processID']
        command('open', projectID=project_id, folderID=folder_id)
        wait_for(lambda: state()['sheetWindow'] and state()['sheet'], 'new worktree sheet visible')
        command('configure', branch='bad branch', task='Fixture initial task --literal')
        wait_for(lambda: state()['sheet']['canLaunch'], 'branch entered')
        command('launch')
        wait_for(lambda: state()['sheet']['failure'] and not state()['sheet']['busy'], 'invalid branch error')
        assert len(call('snapshot')['store']['worktrees']) == 0
        command('configure', branch='task/quick-fixture')
        wait_for(lambda: state()['sheet']['branch'] == 'task/quick-fixture' and state()['sheet']['destination'].endswith('/task-quick-fixture'), 'destination preview')
        screenshot('create-sheet')
        command('launch')
        failed = wait_for(lambda: (s if (s := state())['sheet']['worktreeID'] and s['sheet']['failure'] and not s['sheet']['busy'] else None), 'worktree retained after failed agent')
        tree_id, tree_path = failed['sheet']['worktreeID'], failed['sheet']['path']
        screenshot('retained-worktree')
        trees = call('snapshot')['store']['worktrees']
        assert len(trees) == 1 and trees[0]['value']['id'] == tree_id
        assert Path(tree_path).is_dir()
        (root / 'fail-version').unlink()
        command('launch')
        finished = wait_for(lambda: (s if (s := state())['sheet'] is None and s['selectedSession'] else None), 'session selected and sheet dismissed')
        agent = wait_for(lambda: json.loads((root / 'agent-started.json').read_text()), 'fixture agent running')
        assert agent['cwd'] == tree_path and 'Fixture initial task --literal' in agent['args']
        snapshot = call('snapshot')
        live = [s for s in snapshot['sessions'] if s['id'] == finished['selectedSession']]
        assert len(live) == 1 and live[0]['state'] == 'activityUnknown' and live[0]['worktreeID'] == tree_id
        assert len(snapshot['store']['worktrees']) == 1
        assert state()['error'] is None
        summary = {'passed': True, 'nativeSheetOpenedFromRepository': True, 'invalidBranchDoesNotCreateCheckout': True, 'failedAgentRetainsWorktree': True, 'freshLaunchReusesSelectedWorktree': True, 'initialTaskPreserved': True, 'sessionSelectedAfterLaunch': True, 'worktreesCreated': 1}
        (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))
    finally:
        if (root / 'quick-state.json').exists():
            shutil.copy(root / 'quick-state.json', artifacts / 'last-state.json')
            app_pid = state()['processID']
        if app_pid:
            subprocess.run(['/bin/kill', '-TERM', str(app_pid)], capture_output=True)
        subprocess.run(['tmux', '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        runtime_log.close()
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
