#!/usr/bin/env python3
"""Native worktree manager controls through macOS accessibility actions.

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
import sys
import tempfile
import time
import uuid

repository = Path(__file__).resolve().parents[1]
artifacts = repository / '.build/worktree-controls-artifacts'
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

with tempfile.TemporaryDirectory(prefix='chauffeur-controls-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur.app', app, symlinks=True)
    identifier = 'dev.chauffeur.controls-probe.' + uuid.uuid4().hex
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

    def screenshot(name):
        # State publication precedes SwiftUI's next native layout/display pass.
        time.sleep(0.5)
        window = state()['sheetWindow']
        assert window
        subprocess.run(['/usr/sbin/screencapture', '-x', '-l', str(window), str(artifacts / (name + '.png'))], check=True)

    try:
        wait_for(lambda: call('status'), 'runtime ready')
        repo = root / 'repo 日本語'; repo.mkdir()
        def git(*arguments):
            return subprocess.run(['/usr/bin/git', '-C', str(repo), '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *arguments], capture_output=True, check=True)
        git('init', '-b', 'main')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'Initial')
        external = root / 'external checkout'
        git('worktree', 'add', '-b', 'external', str(external), 'HEAD')
        marker = external / 'keep.txt'; marker.write_text('Keep external files')
        other_repo = root / 'second repo'; other_repo.mkdir()
        for args in [['init', '-b', 'main'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'Initial']]:
            subprocess.run(['/usr/bin/git', '-C', str(other_repo), '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *args], capture_output=True, check=True)
        other_folder_id = uid()
        # Hold the real Git operation briefly so native busy controls can be
        # observed reliably, without changing the app's implementation.
        hooks = root / 'hooks'; hooks.mkdir()
        entered, release = root / 'checkout-entered', root / 'checkout-release'
        hook = hooks / 'post-checkout'
        hook.write_text('#!' + sys.executable + '\nfrom pathlib import Path\nimport time\n'
            + 'Path(' + repr(str(entered)) + ').touch()\n'
            + 'deadline = time.monotonic() + 15\n'
            + 'while not Path(' + repr(str(release)) + ').exists():\n'
            + '    if time.monotonic() >= deadline: raise SystemExit(1)\n'
            + '    time.sleep(0.05)\n')
        hook.chmod(0o700)
        git('config', 'core.hooksPath', str(hooks))
        set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Controls fixture', 'revision': 1, 'archived': False}})
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Fixture agent', 'kind': 'codex', 'executable': str(repository / 'Prototypes/fake_cli.py'), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Worktree Controls Fixture', 'presetSetID': set_id,
            'folders': [{'id': folder_id, 'name': repo.name, 'selectedPath': str(repo), 'canonicalPath': str(repo), 'availability': 'available', 'registered': True},
                        {'id': other_folder_id, 'name': other_repo.name, 'selectedPath': str(other_repo), 'canonicalPath': str(other_repo), 'availability': 'available', 'registered': True}],
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        subprocess.run([str(binary_dir / 'chauffeur-launcher'), str(repo)], capture_output=True, check=True)
        ready = wait_for(lambda: (s if (s := state())['online'] and s['ready'] else None), 'project window ready')
        app_pid = ready['processID']
        call('refreshWorktrees'); command('refresh')
        # Select A, then right-click B without first selecting it. Repeat with
        # alternating repositories and a discovered worktree's context menu.
        ax('press', 'repository.' + folder_id)
        for row_id, expected_repo in [('repository.' + other_folder_id, other_repo), ('repository.' + folder_id, repo), ('repository.' + other_folder_id, other_repo), ('repository.worktree.' + str(external), repo)]:
            if row_id.startswith('repository.worktree.') and control(row_id) is None:
                # SwiftUI's native outline can collapse a repository after its
                # label is pressed. Expand its disclosure before targeting a child.
                items = controls()
                parent = next(c for c in items if c['identifier'] == 'repository.' + folder_id)
                disclosure = min((c for c in items if c['role'] == 'AXDisclosureTriangle'), key=lambda c: abs(c['frame']['y'] - parent['frame']['y']))
                window = next(c for c in items if c['role'] == 'AXWindow')
                ax('click', role='AXWindow', x=disclosure['frame']['x'] + disclosure['frame']['width'] / 2 - window['frame']['x'], y=disclosure['frame']['y'] + disclosure['frame']['height'] / 2 - window['frame']['y'])
            row = wait_for(lambda: control(row_id), 'repository row visible: ' + row_id)
            ax('rightClick', row_id, x=min(30, row['frame']['width'] / 2), y=row['frame']['height'] / 2)
            wait_for(lambda: any(c['role'] == 'AXMenuItem' and c['title'] == 'Manage Worktrees…' for c in controls()), 'context menu visible')
            ax('press', title='Manage Worktrees…', role='AXMenuItem')
            wait_for(lambda: (c := control('worktrees.repository')) and c['value'] == expected_repo.name, 'context repository selected')
            wait_for(lambda: control('worktrees.done')['enabled'], 'inventory loaded')
            ax('press', 'worktrees.done')
            wait_for(lambda: state()['sheetWindow'] is None, 'manager dismissed')
        command('openWorktrees', projectID=project_id, folderID=uid())
        wait_for(lambda: (c := control('worktrees.repository')) and c['value'] == repo.name, 'missing target falls back to first repository')
        wait_for(lambda: control('worktrees.done')['enabled'], 'fallback inventory loaded')
        ax('press', 'worktrees.done')
        wait_for(lambda: state()['sheetWindow'] is None, 'fallback manager dismissed')
        command('openWorktrees', projectID=project_id, folderID=folder_id)
        wait_for(lambda: state()['sheetWindow'], 'worktree manager visible')
        (artifacts / 'controls.json').write_text(json.dumps(controls(), indent=2))
        wait_for(lambda: control('worktrees.branch'), 'branch field exposed')
        assert not control('worktrees.create')['enabled']
        ax('typeText', 'worktrees.branch', value='bad branch')
        wait_for(lambda: control('worktrees.create')['enabled'], 'create button enabled')
        ax('press', 'worktrees.create')
        wait_for(lambda: control('worktrees.error'), 'invalid branch error')
        assert not call('snapshot')['store']['worktrees']
        screenshot('invalid-branch')
        ax('typeText', 'worktrees.branch', value='fixture/native-controls')
        preview = call('previewWorktree', {'projectID': project_id, 'folderID': folder_id, 'branch': 'fixture/native-controls'})['path']
        wait_for(lambda: (v if (v := control('worktrees.destination')) and v['value'] == preview else None), 'current destination preview')
        ax('press', 'worktrees.create')
        wait_for(entered.exists, 'Git checkout hook entered')
        blocked_controls = controls()
        for control_id in ['worktrees.done', 'worktrees.repository', 'worktrees.refresh', 'worktrees.branch', 'worktrees.base', 'worktrees.create', 'worktrees.register.' + str(external)]:
            assert not next(item for item in blocked_controls if item['identifier'] == control_id)['enabled'], control_id
        (artifacts / 'busy-controls.json').write_text(json.dumps(blocked_controls, indent=2))
        release.touch()
        def registered():
            return [item['value'] for item in call('snapshot')['store']['worktrees'] if item['value']['registered']]
        created = wait_for(lambda: next((item for item in registered() if item['managed']), None), 'managed worktree created')
        remove_id = 'worktrees.remove.' + created['id']
        wait_for(lambda: (v if (v := control(remove_id)) and v['enabled'] else None), 'managed remove control')
        assert control('worktrees.branch')['value'] == ''
        assert not control('worktrees.create')['enabled']
        screenshot('managed-worktree')
        # Register and unregister through the native controls and confirmation.
        ax('press', 'worktrees.register.' + str(external))
        registered_external = wait_for(lambda: next((item for item in registered() if item['path'] == str(external)), None), 'external worktree registered')
        external_remove = 'worktrees.remove.' + registered_external['id']
        wait_for(lambda: (v if (v := control(external_remove)) and v['enabled'] else None), 'external unregister control')
        ax('press', external_remove)
        (artifacts / 'confirmation-controls.json').write_text(json.dumps(controls(), indent=2))
        ax('press', title='Cancel')
        assert any(item['id'] == registered_external['id'] for item in registered())
        ax('press', external_remove)
        ax('press', title='Unregister Worktree')
        wait_for(lambda: not any(item['id'] == registered_external['id'] for item in registered()), 'external record unregistered')
        assert marker.read_text() == 'Keep external files'
        # A dirty managed checkout must survive the native Remove confirmation.
        dirty = Path(created['path']) / 'untracked.txt'; dirty.write_text('Keep managed edits')
        wait_for(lambda: (v if (v := control(remove_id)) and v['enabled'] else None), 'remove ready')
        ax('press', remove_id)
        ax('press', title='Remove Worktree')
        wait_for(lambda: control('worktrees.error'), 'dirty worktree error')
        assert dirty.read_text() == 'Keep managed edits'
        screenshot('dirty-removal-refused')
        dirty.unlink()
        ax('press', remove_id)
        ax('press', title='Remove Worktree')
        wait_for(lambda: not any(item['id'] == created['id'] for item in registered()), 'clean worktree removed')
        assert not Path(created['path']).exists()
        git('show-ref', '--verify', 'refs/heads/fixture/native-controls')
        wait_for(lambda: control('worktrees.done')['enabled'], 'manager idle')
        ax('press', 'worktrees.done')
        wait_for(lambda: state()['sheetWindow'] is None, 'manager dismissed')
        report = {'passed': True, 'nativeAccessibilityActions': True, 'contextMenuRepositorySelection': True, 'repeatedRepositorySwitching': True, 'worktreeContextSelectsOwner': True, 'missingRepositoryFallback': True, 'invalidBranchRecovery': True,
            'createAndDestinationPreview': True, 'busyControlsDisabled': True, 'confirmationCancellation': True,
            'externalUnregisterPreservesFiles': True, 'dirtyRemovalPreservesFiles': True,
            'cleanRemovalPreservesBranch': True, 'OSAccessibilityControls': 'pass', 'XCUITest': 'not exercised'}
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
