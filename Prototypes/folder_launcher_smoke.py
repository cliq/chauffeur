#!/usr/bin/env python3
"""Launch Services routing through the bundled terminal command; isolated app/store.

No provider accounts, agents, system command installation, or default service writes.
Uses LSEnvironment in the test copy so cold Launch Services starts reach the fixture.
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
source_app = repository / 'build/Build/Products/Debug/Chauffeur.app'
assert not (source_app / 'Contents/MacOS/Chauffeur').samefile(source_app / 'Contents/MacOS/chauffeur-launcher'), 'Launcher must not replace the app executable'
artifacts = repository / '.build/folder-launcher-artifacts'
artifacts.mkdir(exist_ok=True)

def uid():
    return str(uuid.uuid4()).upper()

def wait_for(probe, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = probe()
            if result:
                return result
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.1)
    raise AssertionError('Timed out waiting for native launcher state')

with tempfile.TemporaryDirectory(prefix='chauffeur-launcher-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(source_app, app, symlinks=True)
    identifier = 'dev.chauffeur.launcher-probe.' + uuid.uuid4().hex
    socket_path = str(root / 'runtime/runtime.sock')
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIdentifier'] = identifier
    info['LSEnvironment'] = {'CHAUFFEUR_SOCKET': socket_path, 'CHAUFFEUR_LAUNCHER_PROBE_DIR': str(root)}
    info_path.write_bytes(plistlib.dumps(info))
    # Keep signing material out of stdout and reports.
    signing = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
    identities = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]+) "Developer ID Application:[^"]+"', signing.stdout, re.M)
    assert len(identities) == 1, 'Expected one local Developer ID identity'
    with (artifacts / 'sign.log').open('w') as log:
        subprocess.run(['codesign', '--force', '--sign', identities[0], '--preserve-metadata=entitlements,flags,runtime', str(app)], stdout=log, stderr=log, check=True)
    binary_dir = app / 'Contents/MacOS'
    launcher = root / 'bin/chauffeur'
    launcher.parent.mkdir()
    launcher.symlink_to(binary_dir / 'chauffeur-launcher')
    runtime_log = (artifacts / 'runtime.log').open('w')
    runtime = subprocess.Popen([str(binary_dir / 'ChauffeurRuntime'), '--data-dir', str(root)], stdout=runtime_log, stderr=runtime_log)
    pids = set()
    def exact(connection, count):
        data = bytearray()
        while len(data) < count:
            part = connection.recv(count - len(data))
            assert part, 'Socket closed'
            data.extend(part)
        return data
    def call(method, params=None):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(15); connection.connect(socket_path)
            data = json.dumps({'version': 1, 'id': uid(), 'method': method, 'params': params or {}}).encode()
            connection.sendall(struct.pack('!I', len(data)) + data)
            count, = struct.unpack('!I', exact(connection, 4))
            assert count <= 8 * 1024 * 1024
            response = json.loads(exact(connection, count))
            assert not response.get('error'), response.get('error')
            return response.get('result')
    def state():
        data = json.loads((root / 'launcher-state.json').read_text())
        pids.add(data['processID'])
        return data
    def command(action, **kwargs):
        temp = root / 'launcher-command.tmp'
        temp.write_text(json.dumps({'action': action, **kwargs}))
        temp.replace(root / 'launcher-command.json')
    def run(args=(), cwd=None, success=True):
        result = subprocess.run([str(launcher), *map(str, args)], cwd=cwd or root, capture_output=True, text=True, timeout=25)
        assert (result.returncode == 0) == success, (result.returncode, result.stderr)
        return result
    def exited(pid):
        return subprocess.run(['/bin/kill', '-0', str(pid)], capture_output=True).returncode != 0
    try:
        wait_for(lambda: call('status'))
        set_id = uid()
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Launcher fixture', 'revision': 1, 'archived': False}})
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        def project(name, path):
            project_id, folder_id = uid(), uid()
            record = {'id': project_id, 'name': name, 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': path.name, 'selectedPath': str(path), 'canonicalPath': str(path), 'availability': 'available', 'registered': True}], 'groups': [{'id': uid(), 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}
            call('saveProject', {'record': record})
            return project_id, folder_id
        repo_a = root / "repo A 日本語 ' & $()"
        repo_b = root / 'repo-b'
        for path in [repo_a / 'Sources', repo_b / 'Sources', root / 'unregistered']:
            path.mkdir(parents=True)
        a, folder_a = project('A', repo_a)
        b, folder_b = project('B', repo_b)
        call('saveWindow', {'record': {'id': b, 'tabs': [], 'sidebarVisible': True, 'wasOpen': True}})
        # Cold start via the symlink, using cwd; unrelated saved windows stay closed.
        run(cwd=repo_a / 'Sources')
        cold = wait_for(lambda: (s if (s := state()).get('online') and s['windows'] == ['project-' + a] and s['selectedFolders'].get(a) == folder_a else None))
        first_pid = cold['processID']
        run([repo_b / 'Sources'])
        wait_for(lambda: (s if sorted((s := state())['windows']) == sorted(['project-' + a, 'project-' + b]) and s['selectedFolders'].get(b) == folder_b else None))
        alias = root / 'alias'; alias.symlink_to(repo_b / 'Sources')
        run([alias]); run(['Sources'], cwd=repo_b)
        warm = wait_for(lambda: (s if len((s := state())['windows']) == 2 and s['processID'] == first_pid else None))
        # Window changes during service loss must remain queued, not become
        # permanent edit conflicts or show a stale startup alert.
        runtime.terminate(); runtime.wait(timeout=10)
        wait_for(lambda: not state()['online'])
        command('hideSidebar', projectID=b)
        time.sleep(0.5)
        assert state().get('error') is None, state().get('error')
        runtime = subprocess.Popen([str(binary_dir / 'ChauffeurRuntime'), '--data-dir', str(root)], stdout=runtime_log, stderr=runtime_log)
        wait_for(lambda: state()['online'])
        wait_for(lambda: any(w['value']['id'] == b and not w['value']['sidebarVisible'] for w in call('snapshot')['store']['windows']))
        assert state().get('error') is None
        regular = root / 'regular-file'; regular.write_text('fixture')
        run([regular], success=False); run(['--unknown'], success=False); run([repo_a, repo_b], success=False)
        run([root / 'unregistered'])
        wait_for(lambda: (s if 'No Chauffeur project' in ((s := state()).get('error') or '') and s['welcomeVisible'] else None))
        command('clearError')
        wait_for(lambda: state().get('error') is None)
        c, folder_c = project('Shared A', repo_a)
        wait_for(lambda: state()['projectCount'] == 3)
        run([repo_a])
        wait_for(lambda: sorted(state()['choices']) == sorted([a, c]))
        command('choose', projectID=c)
        chosen = wait_for(lambda: (s if 'project-' + c in (s := state())['windows'] and s['selectedFolders'].get(c) == folder_c and not s['choices'] else None))
        command('quit'); wait_for(lambda: exited(first_pid))
        (root / 'launcher-state.json').unlink(missing_ok=True)
        run([repo_b])
        restarted = wait_for(lambda: (s if (s := state())['online'] and s['processID'] != first_pid and s['windows'] == ['project-' + b] and s['selectedFolders'].get(b) == folder_b else None))
        command('quit'); wait_for(lambda: exited(restarted['processID']))
        assert len(call('snapshot')['sessions']) == 0
        summary = {'passed': True, 'coldFromWorkingDirectory': True, 'warmExplicitRelativeAndSymlinkPaths': True, 'repeatedRoutesNoDuplicateWindows': True, 'sharedFolderChooser': True, 'invalidArgumentsRejected': True, 'unregisteredFolderError': True, 'coldRestartOpensOnlyRequestedProject': True, 'layoutSavedAfterServiceRestart': True, 'sessionsLaunched': 0}
        (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))
    finally:
        if (root / 'launcher-state.json').exists():
            shutil.copy(root / 'launcher-state.json', artifacts / 'last-state.json')
            try: pids.add(state()['processID'])
            except (OSError, ValueError): pass
        for pid in pids:
            if not exited(pid):
                subprocess.run(['/bin/kill', '-TERM', str(pid)], capture_output=True)
                wait_for(lambda: exited(pid))
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        runtime_log.close()
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
