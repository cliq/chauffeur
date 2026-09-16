#!/usr/bin/env python3
"""Native session details, window commands and stop/quit confirmations.

Uses an isolated signed Debug copy, two project windows and fixture CLI sessions.
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
artifacts = repository / '.build/session-controls-artifacts'
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

with tempfile.TemporaryDirectory(prefix='chauffeur-session-controls-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    for fixture in ('fake_cli.py', 'fake_tui.py'):
        shutil.copy2(repository / 'Prototypes' / fixture, root / fixture)
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur Debug.app', app, symlinks=True)
    identifier = 'dev.chauffeur.session-controls-probe.' + uuid.uuid4().hex
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
    runtime = subprocess.Popen([str(binary_dir / 'ChauffeurRuntime'), '--data-dir', str(root)], cwd=root, stdout=runtime_log, stderr=runtime_log)
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
        return result

    def screenshot(name):
        # State publication precedes SwiftUI's next native layout/display pass.
        time.sleep(0.5)
        window = state()['sheetWindow'] or window_id
        assert window
        subprocess.run(['/usr/sbin/screencapture', '-x', '-l', str(window), str(artifacts / (name + '.png'))], check=True)

    def text_values(items=None):
        return '\n'.join(c.get('value', '') + '\n' + c.get('title', '') + '\n' + c.get('label', '') for c in (items or controls()))
    def window_state(project):
        return next(w['value'] for w in call('snapshot')['store']['windows'] if w['value']['id'] == project)
    def live_ids():
        return {s['id'] for s in call('snapshot')['sessions'] if s['state'] in ['starting', 'running', 'needsAttention', 'turnFinished', 'activityUnknown']}
    def stop_all():
        wait_for(lambda: any(c['title'] == 'Stop All Sessions and Quit…' and c['enabled'] for c in accessibility('inspect', includeMenus=True)), 'Stop All menu enabled')
        ax('press', title='Stop All Sessions and Quit…', role='AXMenuItem', includeMenus=True)
        wait_for(lambda: any('Stop All and Quit' in [c['label'], c['title']] for c in controls()), 'Stop All confirmation')
        buttons = [c for c in controls() if c['role'] == 'AXButton' and 'Stop All and Quit' in [c['label'], c['title']]]
        assert len(buttons) == 1, 'Stop All must show one confirmation across project windows'
    try:
        wait_for(lambda: call('status'), 'runtime ready')
        repo = root / 'terminal repository'; repo.mkdir()
        cli = root / 'fake_cli.py'
        set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Controls fixture', 'revision': 1, 'archived': False}})
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Fixture agent', 'kind': 'codex', 'executable': str(cli), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Session Controls A', 'presetSetID': set_id,
            'folders': [{'id': folder_id, 'name': 'Terminal repository', 'selectedPath': str(repo), 'canonicalPath': str(repo), 'availability': 'available', 'registered': True}],
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id,
            'folderID': folder_id, 'additionalFolderIDs': [], 'title': 'First session',
            'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
        session_id = session['id']
        second = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id,
            'folderID': folder_id, 'additionalFolderIDs': [], 'title': 'Second session',
            'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
        project_b, folder_b, group_b, resistant_preset = [uid() for _ in range(4)]
        repo_b = root / 'second repository'; repo_b.mkdir()
        resistant_cli = root / 'resistant-cli'
        resistant_cli.write_text('#!' + sys.executable + '\nimport signal,runpy\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n'
                                + 'runpy.run_path(' + repr(str(cli)) + ', run_name="__main__")\n')
        resistant_cli.chmod(0o700)
        call('savePreset', {'record': {'id': resistant_preset, 'setID': set_id, 'name': 'Resistant fixture', 'kind': 'codex', 'executable': str(resistant_cli), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_b, 'name': 'Session Controls B', 'presetSetID': set_id,
            'folders': [{'id': folder_b, 'name': 'Second repository', 'selectedPath': str(repo_b), 'canonicalPath': str(repo_b), 'availability': 'available', 'registered': True}],
            'groups': [{'id': group_b, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        resistant = call('launch', {'projectID': project_b, 'groupID': group_b, 'presetID': resistant_preset,
            'folderID': folder_b, 'additionalFolderIDs': [], 'title': 'Resistant session',
            'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
        for project, tabs in [(project_id, [session_id, second['id']]), (project_b, [resistant['id']])]:
            call('saveWindow', {'record': {'id': project, 'tabs': tabs, 'selectedSessionID': tabs[0], 'sidebarVisible': True, 'wasOpen': True}})
        subprocess.run(['/usr/bin/open', str(app)], check=True)
        ready = wait_for(lambda: (s if (s := state())['online'] and s['ready'] else None), 'project window ready')
        app_pid = ready['processID']
        wait_for(lambda: len([c for c in controls() if c['role'] == 'AXWindow' and c['title'].startswith('Session Controls')]) == 2, 'both project windows')
        windows = json.loads(subprocess.check_output(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], text=True))
        window_id = max(windows['visibleWindows'], key=lambda w: w['bounds']['Width'])['id']
        terminal_id = 'terminal-' + session_id
        terminal_b = 'terminal-' + resistant['id']
        wait_for(lambda: control(terminal_id) and 'Chauffeur fixture' in control(terminal_id)['value'], 'first terminal ready')
        ax('key', terminal_id, keyCode=53)
        if '--quit-only' in sys.argv:
            original_live = live_ids()
            def request_quit():
                ax('press', title='Quit Chauffeur', role='AXMenuItem', includeMenus=True)
                wait_for(lambda: 'Keep All Sessions Running & Quit' in text_values(), 'quit choice shown')
            request_quit()
            ax('press', title='Cancel')
            wait_for(lambda: 'Keep All Sessions Running & Quit' not in text_values(), 'quit cancelled')
            assert live_ids() == original_live
            # Regression: a cancelled quit must not starve asynchronous editor saves.
            ax('press', title='Settings…', role='AXMenuItem', includeMenus=True)
            wait_for(lambda: any(c['title'] == 'Agent Presets' for c in controls()), 'settings opened')
            ax('press', title='Agent Presets')
            ax('press', title='Add Team…')
            wait_for(lambda: control('preset-set.name'), 'preset editor')
            ax('typeText', 'preset-set.name', value='After cancelled quit')
            ax('press', 'preset-set.save')
            wait_for(lambda: any(r['value']['name'] == 'After cancelled quit' for r in call('snapshot')['store']['presetSets']), 'editor saves after cancelled quit')
            ax('closeWindow', identifier='com_apple_SwiftUI_Settings_window')
            for title in ['Session Controls A', 'Session Controls B']:
                ax('closeWindow', title=title, role='AXWindow')
            request_quit()  # Standalone prompt with no project windows.
            ax('press', title='Review Sessions')
            wait_for(lambda: any(c['role'] == 'AXWindow' and c['title'].startswith('Session Controls') for c in controls()), 'review opens a project')
            wait_for(lambda: any(c['identifier'].startswith('terminal-') and c['identifier'][9:] in original_live for c in controls()), 'review shows an active terminal')
            assert live_ids() == original_live
            request_quit()
            ax('press', title='Keep All Sessions Running & Quit')
            wait_for(lambda: subprocess.run(['/bin/kill', '-0', str(app_pid)], capture_output=True).returncode != 0, 'keep-running quits app')
            assert live_ids() == original_live
            assert call('status')['runtimeID'] == session['runtimeID']
            report = {'passed': True, 'cancelPreservesSessions': True, 'saveAfterCancelledQuit': True,
                      'reviewOpensActiveSessionWithoutWindows': True, 'keepRunningQuitsUIOnly': True}
            (artifacts / 'quit-summary.json').write_text(json.dumps(report, indent=2))
            print(json.dumps(report, indent=2), flush=True)
            sys.exit(0)
        # One shared error must not create a sheet in every project and Welcome
        # window. Repeated errors coalesce while distinct errors remain queued.
        unregistered = [root / ('unregistered-' + name) for name in ['one', 'two']]
        for folder in unregistered: folder.mkdir()
        def open_unregistered(folder):
            subprocess.run([str(binary_dir / 'chauffeur-launcher'), str(folder)], capture_output=True, check=True)
        def error_buttons():
            return [c for c in controls() if c['role'] == 'AXButton' and 'OK' in [c['label'], c['title']]]
        open_unregistered(unregistered[0])
        wait_for(lambda: str(unregistered[0]) in text_values() and error_buttons(), 'folder routing error')
        time.sleep(.4)
        assert len(error_buttons()) == 1, 'An app error must have one dialog across all windows'
        open_unregistered(unregistered[0])
        open_unregistered(unregistered[1])
        time.sleep(.4)
        assert len(error_buttons()) == 1 and str(unregistered[1]) not in text_values(), 'A second error must wait for the first'
        ax('press', title='OK')
        wait_for(lambda: str(unregistered[1]) in text_values() and len(error_buttons()) == 1, 'next queued error')
        ax('press', title='OK')
        wait_for(lambda: not error_buttons(), 'errors dismissed once each')
        open_unregistered(unregistered[0])
        wait_for(lambda: str(unregistered[0]) in text_values() and len(error_buttons()) == 1, 'same error can be reported again after dismissal')
        ax('press', title='OK')
        wait_for(lambda: not error_buttons(), 'repeated error dismissed')
        ax('closeWindow', title='Welcome to Chauffeur Debug', role='AXWindow')
        assert live_ids() == {session_id, second['id'], resistant['id']}
        ax('key', terminal_id, keyCode=53)
        # Details must keep the launch snapshot after the shared preset is edited.
        stored = next(p for p in call('snapshot')['store']['presets'] if p['value']['id'] == preset_id)
        changed = dict(stored['value'], name='Edited preset name')
        call('savePreset', {'record': changed, 'version': stored['version']})
        ax('press', title='Session Details', windowTitle='Session Controls A')
        wait_for(lambda: 'Configuration directory' in text_values(), 'details open')
        detail_text = text_values(accessibility('inspect', windowTitle='Session Controls A'))
        for value in ['Fixture agent', str(root), str(repo), 'Controls fixture · revision ' + str(session['launch']['presetSetRevision'])]:
            assert value in detail_text, ('Missing immutable detail', value)
        assert 'Edited preset name' not in detail_text
        # Native stop confirmation cancellation must leave every process alive.
        ax('press', title='Stop Session…', windowTitle='Session Controls A')
        wait_for(lambda: any(c['label'] == 'Stop Session' for c in controls()), 'individual stop confirmation')
        ax('press', title='Cancel')
        wait_for(lambda: not any(c['label'] == 'Stop Session' for c in controls()), 'stop confirmation dismissed')
        assert live_ids() == {session_id, second['id'], resistant['id']}
        ax('press', title='Stop Session…', windowTitle='Session Controls A')
        wait_for(lambda: any(c['label'] == 'Stop Session' for c in controls()), 'individual stop confirmation again')
        (artifacts / 'stop-confirmation.json').write_text(json.dumps(controls(), indent=2))
        # A destructive macOS confirmation may invalidate its AX element while
        # performing the action. Verify the runtime outcome rather than retrying it.
        stop_action = accessibility('press', title='Stop Session')
        wait_for(lambda: session_id not in live_ids(), 'first session stopped')
        assert live_ids() == {second['id'], resistant['id']}
        # Three failed launches expose attention cycling beyond a two-item toggle.
        bad_preset = uid()
        call('savePreset', {'record': {'id': bad_preset, 'setID': set_id, 'name': 'Invalid executable fixture', 'kind': 'codex',
            'executable': str(root / 'missing-cli'), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        for number in range(3):
            call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': bad_preset,
                'folderID': folder_id, 'additionalFolderIDs': [], 'title': 'Attention failure ' + str(number),
                'allowSharedCheckout': True, 'coordinationEnabled': False, 'retryKey': uid()}, expect_error=True)
        failures = [s for s in call('snapshot')['sessions'] if s['title'].startswith('Attention failure ')]
        assert len(failures) == 3 and all(s['state'] == 'failed' and not s.get('processID') for s in failures)
        # Failed launches stay visible as attention cards in the checkout strip.
        wait_for(lambda: 'Attention failure 2' in text_values(), 'failed launches visible in the checkout strip')
        # The search field lives in the sidebar's Sessions mode.
        ax('press', title='Sessions', role='AXRadioButton', windowTitle='Session Controls A')
        wait_for(lambda: any(c['placeholder'] == 'Search sessions' for c in controls()), 'Sessions mode search field')
        visited = []
        for _ in range(4):
            previous = window_state(project_id)['selectedSessionID']
            ax('key', placeholder='Search sessions', windowTitle='Session Controls A', keyCode=0, modifiers=['command', 'shift'])
            selected = wait_for(lambda: (value if (value := window_state(project_id)['selectedSessionID']) != previous else None), 'next attention selection')
            visited.append(selected)
        assert set(visited[:3]) == {s['id'] for s in failures} and visited[3] == visited[0], 'Next Attention must cycle through every attention item'
        selected_a = window_state(project_id)['selectedSessionID']
        assert window_state(project_b)['selectedSessionID'] == resistant['id']
        # A focused window command must not change the other project's selection.
        ax('press', title='Hide Sidebar', windowTitle='Session Controls B')
        wait_for(lambda: not window_state(project_b)['sidebarVisible'], 'sidebar hidden')
        ax('key', terminal_b, keyCode=40, modifiers=['command'])
        wait_for(lambda: window_state(project_b)['sidebarVisible'], 'Command-K reveals the search sidebar')
        ax('typeText', placeholder='Search sessions', windowTitle='Session Controls B', value='Resistant')
        assert window_state(project_id)['selectedSessionID'] == selected_a
        ax('typeText', placeholder='Search sessions', windowTitle='Session Controls B', value='')
        ax('key', terminal_b, keyCode=45, modifiers=['command'])
        wait_for(lambda: 'Initial task (optional)' in text_values(), 'Command-N new session sheet')
        ax('press', title='Cancel')
        assert live_ids() == {second['id'], resistant['id']}
        ax('key', terminal_b, keyCode=31, modifiers=['command', 'shift'])
        wait_for(lambda: any(c['role'] == 'AXWindow' and c['title'] == 'Welcome to Chauffeur Debug' for c in controls()), 'open project window command')
        ax('closeWindow', title='Welcome to Chauffeur Debug', role='AXWindow')
        ax('key', terminal_b, keyCode=53)  # Focus B without changing its input.
        stop_all()
        confirmation = text_values()
        assert 'Session Controls A · Second session' in confirmation
        assert 'Session Controls B · Resistant session' in confirmation
        ax('press', title='Cancel')
        assert live_ids() == {second['id'], resistant['id']}
        stop_all()
        late = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id,
            'folderID': folder_id, 'additionalFolderIDs': [], 'title': 'Later session',
            'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
        assert 'Session Controls A · Later session' not in text_values(), 'Confirmation targets changed after presentation'
        accessibility('press', title='Stop All and Quit')
        wait_for(lambda: second['id'] not in live_ids(), 'normal session stopped by Stop All')
        wait_for(lambda: 'Some sessions are still stopping' in text_values(), 'resistant stop reported without quitting')
        assert live_ids() == {resistant['id'], late['id']}
        assert subprocess.run(['/bin/kill', '-0', str(app_pid)], capture_output=True).returncode == 0
        ax('press', title='OK')
        ax('press', title='Session Details', windowTitle='Session Controls B')
        wait_for(lambda: 'Force Stop…' in text_values(accessibility('inspect', windowTitle='Session Controls B')), 'resistant details')
        ax('press', title='Force Stop…', windowTitle='Session Controls B')
        wait_for(lambda: any(c['label'] == 'Force Stop' for c in controls()), 'force stop confirmation')
        ax('press', title='Cancel')
        assert live_ids() == {resistant['id'], late['id']}
        wait_for(lambda: not any(c['label'] == 'Force Stop' for c in controls()), 'force confirmation dismissed')
        ax('press', title='Force Stop…', windowTitle='Session Controls B')
        wait_for(lambda: any(c['label'] == 'Force Stop' for c in controls()), 'force stop confirmation again')
        force_action = accessibility('press', title='Force Stop')
        wait_for(lambda: live_ids() == {late['id']}, 'resistant session force-stopped')
        for title in ['Session Controls A', 'Session Controls B']:
            ax('closeWindow', title=title, role='AXWindow')
        wait_for(lambda: not any(c['role'] == 'AXWindow' for c in controls()), 'all windows closed')
        assert live_ids() == {late['id']}
        stop_all()
        assert 'Session Controls A · Later session' in text_values()
        accessibility('press', title='Stop All and Quit')
        wait_for(lambda: subprocess.run(['/bin/kill', '-0', str(app_pid)], capture_output=True).returncode != 0, 'successful Stop All quits UI')
        assert not live_ids()
        assert call('status')['runtimeID'] == session['runtimeID']
        report = {'passed': True, 'immutableSessionDetails': True, 'individualStopCancelAndConfirm': True,
                  'oneAppErrorAcrossWindows': True, 'repeatedErrorsCoalesce': True, 'distinctErrorsQueued': True,
                  'forceStopCancelAndConfirm': True, 'searchAndNewSessionCommands': True, 'openProjectWindowCommand': True,
                  'nextAttentionCyclesAllItems': True, 'missingExecutableDoesNotSpawn': True,
                  'oneStopAllConfirmation': True, 'stopAllCancelPreservesAgents': True,
                  'stopAllTargetsFrozenAtConfirmation': True, 'stopAllWithoutProjectWindows': True,
                  'resistantStopKeepsAppOpen': True, 'stopAllStopsShownTargetsAndQuits': True,
                  'backgroundRuntimeRemains': True}
        (artifacts / 'destructive-action-status.json').write_text(json.dumps({'stop': stop_action, 'force': force_action}, indent=2))
        (artifacts / 'summary.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    except Exception:
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
