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

with tempfile.TemporaryDirectory(prefix='chauffeur-quick-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur Debug.app', app, symlinks=True)
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
        temporary = root / 'quick-command.tmp'
        temporary.write_text(json.dumps({'action': action, **fields}))
        temporary.replace(root / 'quick-command.json')
        wait_for(lambda: not (root / 'quick-command.json').exists(), 'command consumed')

    def screenshot(name):
        # State publication precedes SwiftUI's next native layout/display pass.
        time.sleep(0.5)
        window = state()['sheetWindow'] or state()['projectWindow']
        assert window
        subprocess.run(['/usr/sbin/screencapture', '-x', '-l', str(window), str(artifacts / (name + '.png'))], check=True)

    def type_text(identifier, value):
        result = subprocess.run([str(accessibility_helper)], input=json.dumps({'pid': app_pid, 'operation': 'typeText', 'identifier': identifier, 'value': value}), text=True, capture_output=True, check=True)
        response = json.loads(result.stdout)
        assert response.get('performed'), response

    def accessibility(operation, **fields):
        result = subprocess.run([str(accessibility_helper)], input=json.dumps({'pid': app_pid, 'operation': operation, **fields}), text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def controls():
        return accessibility('inspect')

    def control(identifier):
        return next((c for c in controls() if c['identifier'] == identifier), None)

    def ax(operation, **fields):
        result = accessibility(operation, **fields)
        assert result.get('performed'), result

    try:
        wait_for(lambda: call('status'), 'runtime ready')
        repo = root / 'repo 日本語'; repo.mkdir()
        for args in [['init', '-b', 'main'], ['config', 'core.hooksPath', '/dev/null'], ['config', 'commit.gpgsign', 'false'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'Initial']]:
            subprocess.run(['/usr/bin/git', '-C', str(repo), *args], capture_output=True, check=True)
        # Enough existing worktrees to put the new, alphabetically later row
        # below the viewport unless creation really scrolls it into view.
        for index in range(22):
            subprocess.run(['/usr/bin/git', '-C', str(repo), 'worktree', 'add', '-b', f'aa-existing-{index:02}', str(root / f'existing-{index:02}'), 'HEAD'], capture_output=True, check=True)
        other_repo = root / 'second repo'; other_repo.mkdir()
        for args in [['init', '-b', 'main'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-m', 'Initial']]:
            subprocess.run(['/usr/bin/git', '-C', str(other_repo), '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', *args], capture_output=True, check=True)
        other_folder_id = uid()
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
        default_id = uid()
        call('savePreset', {'record': {'id': default_id, 'setID': set_id, 'name': 'Default agent', 'kind': 'claude', 'executable': str(fake), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        preset_set = call('snapshot')['store']['presetSets'][0]
        preset_set['value']['defaultPresetID'] = default_id
        preset_set = call('savePresetSet', {'record': preset_set['value'], 'version': preset_set['version']})
        call('saveProject', {'record': {'id': project_id, 'name': 'Quick Session Fixture', 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': repo.name, 'selectedPath': str(repo), 'canonicalPath': str(repo), 'availability': 'available', 'registered': True}, {'id': other_folder_id, 'name': other_repo.name, 'selectedPath': str(other_repo), 'canonicalPath': str(other_repo), 'availability': 'available', 'registered': True}], 'groups': [{'id': uid(), 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        subprocess.run([str(binary_dir / 'chauffeur-launcher'), str(repo)], capture_output=True, check=True)
        ready = wait_for(lambda: (s if (s := state())['online'] and s['ready'] else None), 'project window ready')
        app_pid = ready['processID']
        call('refreshWorktrees'); command('refresh')
        items = controls()
        parent = next(c for c in items if c['identifier'] == 'repository.' + folder_id)
        disclosure = min((c for c in items if c['role'] == 'AXDisclosureTriangle'), key=lambda c: abs(c['frame']['y'] - parent['frame']['y']))
        window = next(c for c in items if c['role'] == 'AXWindow')
        ax('click', role='AXWindow', x=disclosure['frame']['x'] + disclosure['frame']['width'] / 2 - window['frame']['x'], y=disclosure['frame']['y'] + disclosure['frame']['height'] / 2 - window['frame']['y'])
        wait_for(lambda: control('repository.new-worktree.' + folder_id) is None, 'repository collapsed')
        ax('press', title='Hide Sidebar')
        wait_for(lambda: not state()['sidebarVisible'], 'sidebar hidden before creation')
        command('open', projectID=project_id, folderID=folder_id)
        wait_for(lambda: state()['sheetWindow'] and state()['sheet'], 'new worktree sheet visible')
        assert state()['sheet']['presetID'] == default_id
        # Real text controls: suggestions keep following the title until a
        # manual branch is supplied, and clearing it restores automatic naming.
        type_text('session.title', 'Fix login')
        wait_for(lambda: state()['sheet']['branch'] == 'fix-login' and state()['sheet']['destination'].endswith('/fix-login'), 'initial title suggestion')
        type_text('session.title', 'Fix login flow')
        wait_for(lambda: state()['sheet']['branch'] == 'fix-login-flow' and state()['sheet']['destination'].endswith('/fix-login-flow'), 'updated title suggestion')
        type_text('session.branch', 'feature/manual')
        type_text('session.title', 'Another title')
        wait_for(lambda: state()['sheet']['branch'] == 'feature/manual' and state()['sheet']['destination'].endswith('/feature-manual'), 'manual override survives title edit')
        type_text('session.branch', '')
        wait_for(lambda: state()['sheet']['branch'] == 'another-title' and state()['sheet']['destination'].endswith('/another-title'), 'clearing branch restores suggestion')
        type_text('session.title', '...@{}?!')
        wait_for(lambda: not state()['sheet']['branch'] and not state()['sheet']['destination'] and not state()['sheet']['canLaunch'], 'punctuation-only title cannot create')
        type_text('session.title', 'Fix...login @{flow} / retry.lock?')
        wait_for(lambda: state()['sheet']['branch'] == 'fix-login-flow-retry-lock' and state()['sheet']['canLaunch'], 'sanitized title is launchable')
        first_destination = state()['sheet']['destination']
        command('configure', folderID=other_folder_id)
        expected = call('previewWorktree', {'projectID': project_id, 'folderID': other_folder_id, 'branch': 'fix-login-flow-retry-lock'})['path']
        wait_for(lambda: state()['sheet']['destination'] == expected and state()['sheet']['canLaunch'], 'destination follows repository change')
        assert expected != first_destination
        command('configure', folderID=folder_id)
        wait_for(lambda: state()['sheet']['destination'] == first_destination, 'destination restored for original repository')
        screenshot('title-derived-branch')
        command('configure', branch='bad branch', task='Fixture initial task --literal', presetID=preset_id)
        wait_for(lambda: state()['sheet']['previewFailure'] and not state()['sheet']['canLaunch'], 'invalid branch preview blocks creation')
        assert len(call('snapshot')['store']['worktrees']) == 0
        command('configure', branch='task/quick-fixture')
        wait_for(lambda: state()['sheet']['branch'] == 'task/quick-fixture' and state()['sheet']['destination'].endswith('/task-quick-fixture'), 'destination preview')
        screenshot('create-sheet')
        command('launch')
        failed = wait_for(lambda: (s if (s := state())['sheet']['worktreeID'] and s['sheet']['failure'] and not s['sheet']['busy'] else None), 'worktree retained after failed agent')
        tree_id, tree_path = failed['sheet']['worktreeID'], failed['sheet']['path']
        wait_for(lambda: state()['sidebarVisible'] and state()['selectedWorktree'] == tree_path, 'created worktree revealed despite agent failure')
        screenshot('retained-worktree')
        trees = call('snapshot')['store']['worktrees']
        assert len(trees) == 1 and trees[0]['value']['id'] == tree_id
        assert Path(tree_path).is_dir()
        assert call('snapshot')['store']['projects'][0]['value'].get('lastPresetID') is None
        (root / 'fail-version').unlink()
        command('launch')
        # Native dismissal can precede SwiftUI releasing the probe's closure.
        finished = wait_for(lambda: (s if (s := state())['sheetWindow'] is None and s['selectedSession'] else None), 'session selected and sheet dismissed')
        agent = wait_for(lambda: json.loads((root / 'agent-started.json').read_text()), 'fixture agent running')
        assert agent['cwd'] == tree_path and 'Fixture initial task --literal' in agent['args']
        snapshot = call('snapshot')
        live = [s for s in snapshot['sessions'] if s['id'] == finished['selectedSession']]
        assert len(live) == 1 and live[0]['state'] == 'activityUnknown' and live[0]['worktreeID'] == tree_id
        assert len(snapshot['store']['worktrees']) == 1
        assert snapshot['store']['projects'][0]['value']['lastPresetID'] == preset_id
        assert live[0]['launch']['presetSetRevision'] == preset_set['value']['revision']
        def highlighted_row_in_view():
            items = controls()
            row = next((c for c in items if c['identifier'] == 'repository.worktree.' + tree_path), None)
            outline = next((c for c in items if c['role'] == 'AXOutline' and c['label'] == 'Sidebar'), None)
            if not row or not outline or row['value'] != 'Selected worktree':
                return False
            return row['frame']['y'] >= outline['frame']['y'] and row['frame']['y'] + row['frame']['height'] <= outline['frame']['y'] + outline['frame']['height']
        wait_for(highlighted_row_in_view, 'new worktree highlighted and scrolled fully into view')
        screenshot('created-worktree-highlight')
        edited = next(p for p in snapshot['store']['presets'] if p['value']['id'] == preset_id)
        edited['value']['arguments'] = ['--model', 'fixture-model']
        call('savePreset', {'record': edited['value'], 'version': edited['version']})
        updated = call('snapshot')
        assert updated['store']['presetSets'][0]['value']['revision'] == preset_set['value']['revision'] + 1
        retained = next(s for s in updated['sessions'] if s['id'] == live[0]['id'])
        assert retained['launch'] == live[0]['launch']
        command('open', projectID=project_id, folderID=folder_id)
        wait_for(lambda: state()['sheetWindow'] and state()['sheet'] and state()['sheet']['presetID'] == preset_id, 'last-used preset selected instead of set default')
        command('cancel')
        wait_for(lambda: state()['sheetWindow'] is None, 'sheet closed')
        empty_id = uid()
        call('savePresetSet', {'record': {'id': empty_id, 'name': 'Empty fixture set', 'revision': 1, 'archived': False}})
        project = call('snapshot')['store']['projects'][0]
        project['value']['presetSetID'] = empty_id
        project = call('saveProject', {'record': project['value'], 'version': project['version']})
        assert project['value'].get('lastPresetID') is None
        command('refresh')
        command('open', projectID=project_id, folderID=folder_id)
        wait_for(lambda: state()['sheetWindow'] and state()['sheet'] and state()['sheet']['presetID'] is None, 'empty-set sheet')
        command('configure', branch='task/empty-fixture')
        wait_for(lambda: state()['sheet']['branch'] == 'task/empty-fixture', 'empty-set branch entered')
        assert not state()['sheet']['canLaunch']
        screenshot('empty-set')
        missing = call('launch', {'projectID': project_id, 'groupID': project['value']['groups'][0]['id'], 'presetID': preset_id, 'folderID': folder_id, 'title': 'Cannot launch', 'additionalFolderIDs': [], 'allowSharedCheckout': False, 'coordinationEnabled': False, 'retryKey': uid()}, expect_error=True)
        assert missing['code'] == 'missing_preset'
        assert len(call('snapshot')['sessions']) == len(updated['sessions'])
        assert state()['error'] is None
        summary = {'passed': True, 'nativeSheetOpenedFromRepository': True, 'nativeTitleDerivedBranch': True, 'manualOverridePreserved': True, 'clearingOverrideRestoresSuggestion': True, 'emptySanitizedTitleBlocked': True, 'invalidBranchPreviewBlocksCreation': True, 'invalidBranchDoesNotCreateCheckout': True, 'failedAgentRetainsWorktree': True, 'freshLaunchReusesSelectedWorktree': True, 'initialTaskPreserved': True, 'sessionSelectedAfterLaunch': True, 'worktreesCreated': 1, 'lastSuccessfulPresetSelected': True, 'failedLaunchDoesNotChangePreference': True, 'presetRevisionAdvanced': True, 'runningLaunchSnapshotUnchanged': True, 'emptySetSavedButCannotLaunch': True}
        summary['destinationFollowsRepository'] = True
        summary['createdWorktreeRevealsHiddenSidebar'] = True
        summary['createdWorktreeExpandsCollapsedRepository'] = True
        summary['createdWorktreeHighlightedAndScrolledIntoView'] = True
        summary['failedAgentStillHighlightsCreatedWorktree'] = True
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
