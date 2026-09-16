#!/usr/bin/env python3
"""Native SMAppService lifecycle with real CLIs in a private signed app.

The bundled LaunchAgent has a unique label and private data directory. The Debug
socket override keeps actual registration/restart behavior enabled. No default
job, user store, original profile, OS permission setting, or Release is changed.
Provider turns only ask for text and recall; no tools or coordination are used.
"""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
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

os.umask(0o077)
repository = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--registration-only', action='store_true')
parser.add_argument('--sleep-wake', action='store_true',
    help='After live-session recovery, wait for the user to sleep and wake the Mac')
options = parser.parse_args()
assert not (options.registration_only and options.sleep_wake), 'Sleep/wake requires live sessions'


def console_locked():
    state = plistlib.loads(subprocess.check_output(['ioreg', '-n', 'Root', '-d1', '-a']))
    if isinstance(state, list): state = state[0]
    return any(user.get('kCGSSessionUserIDKey') == os.getuid() and user.get('CGSSessionScreenIsLocked', False)
        for user in state.get('IOConsoleUsers', []))


assert not console_locked(), 'Unlock the Mac before running native desktop checks; no test fixture was created'
artifacts = repository / '.local' / ('live-service-registration' if options.registration_only else 'live-service-native')
artifacts.mkdir(mode=0o700, exist_ok=True)
(artifacts / 'summary.json').unlink(missing_ok=True)
helper = repository / '.build/app-accessibility-probe'
subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(helper)], check=True)
subprocess.run(['swiftc', str(repository / 'Prototypes/app_window_probe.swift'), '-o', str(repository / '.build/app-window-probe')], check=True)
if options.sleep_wake:
    subprocess.run(['swiftc', str(repository / 'Prototypes/system_sleep_observer.swift'), '-o', str(repository / '.build/system-sleep-observer')], check=True)
source = repository / 'build/Build/Products/Debug/Chauffeur.app'
release = repository / 'build/Build/Products/Release/Chauffeur.app'
assert (source / 'Contents/MacOS/Chauffeur.debug.dylib').is_file()
for bundle in [source, release]:
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)


def uid():
    return str(uuid.uuid4()).upper()


def wait(probe, label, timeout=45):
    deadline, printed, last_error = time.monotonic() + timeout, 0, None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value: return value
        except (OSError, ValueError) as error:
            last_error = error
        if time.monotonic() - printed > 10:
            print('Waiting:', label, flush=True); printed = time.monotonic()
        time.sleep(.2)
    raise AssertionError('Timed out: ' + label) from last_error


def request(path, method, params=None):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(20)
        connection.connect(str(path))
        data = json.dumps({'version': 1, 'id': uid(), 'method': method, 'params': params or {}}).encode()
        connection.sendall(struct.pack('!I', len(data)) + data)

        def exact(count):
            result = bytearray()
            while len(result) < count:
                chunk = connection.recv(count - len(result))
                if not chunk: raise OSError('Runtime disconnected')
                result.extend(chunk)
            return result

        count, = struct.unpack('!I', exact(4))
        assert count <= 8 * 1024 * 1024
        response = json.loads(exact(count))
        assert not response.get('error'), response.get('error')
        return response['result']


def job_info(label):
    return subprocess.run(['launchctl', 'print', f'gui/{os.getuid()}/{label}'], capture_output=True, text=True)


def pid_path(pid):
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    path = ctypes.create_string_buffer(4096)
    assert libproc.proc_pidpath(pid, path, len(path)) > 0
    return Path(os.fsdecode(path.value)).resolve()


default_socket = Path.home() / 'Library/Application Support/Chauffeur/runtime/runtime.sock'
default_before = request(default_socket, 'snapshot')
release_hash = hashlib.sha256((release / 'Contents/MacOS/ChauffeurRuntime').read_bytes()).hexdigest()
summary = {}
with tempfile.TemporaryDirectory(prefix='chauffeur-live-service-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(source, app, symlinks=True)
    suffix = uuid.uuid4().hex
    identifier = 'dev.chauffeur.live-service-probe.' + suffix
    label = 'dev.chauffeur.runtime.probe.' + suffix
    assert job_info(label).returncode != 0
    job = f'gui/{os.getuid()}/{label}'
    socket_path = root / 'runtime/runtime.sock'
    binaries = app / 'Contents/MacOS'
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info['CFBundleIdentifier'] = identifier
    info['LSEnvironment'] = {'CHAUFFEUR_SERVICE_PROBE_SOCKET': str(socket_path)}
    info_path.write_bytes(plistlib.dumps(info))
    plist = app / 'Contents/Library/LaunchAgents/dev.chauffeur.runtime.plist'
    configuration = plistlib.loads(plist.read_bytes())
    configuration['Label'] = label
    configuration['ProgramArguments'] = ['ChauffeurRuntime', '--data-dir', str(root)]
    configuration['StandardOutPath'] = str(artifacts / 'runtime.private.log')
    configuration['StandardErrorPath'] = str(artifacts / 'runtime-error.private.log')
    plist.write_bytes(plistlib.dumps(configuration))
    # Start with the Release helper, then replace it with the newly built Debug
    # helper at the same bundle path to exercise real registration refresh.
    for name in ['ChauffeurRuntime', 'chauffeurctl']:
        shutil.copy2(release / 'Contents/MacOS' / name, binaries / name)

    def sign_app():
        with (artifacts / 'sign.log').open('a') as log:
            subprocess.run(['codesign', '--force', '--sign', 'Developer ID Application: Leonardo Lobato',
                '--preserve-metadata=entitlements,flags,runtime', str(app)], stdout=log, stderr=log, check=True)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], stdout=log, stderr=log, check=True)

    sign_app()
    (artifacts / 'fixture.private.json').write_text(json.dumps({'app': str(app), 'root': str(root), 'identifier': identifier, 'label': label}, indent=2))
    pid, sessions, staged_credentials, sleep_observer = None, [], [], None

    def stage_profile(kind):
        # The user's authorized test clones live in Documents. A newly signed
        # fixture app has its own macOS file-access consent, so use fresh private
        # copies alongside the test repositories, without changing that consent.
        original = (repository / '.local/profile-isolation' / (kind + '-a')).resolve(strict=True)
        profile = root / (kind + '-profile')
        shutil.copytree(original, profile, symlinks=False, ignore=shutil.ignore_patterns('*.sock', '*.lock', 'session_index.jsonl'))
        profile.chmod(0o700)
        if kind == 'claude':
            def credential_service(path):
                return 'Claude Code-credentials-' + hashlib.sha256(str(path).encode()).hexdigest()[:8]
            service = credential_service(profile)
            assert subprocess.run(['security', 'find-generic-password', '-s', service], capture_output=True).returncode != 0
            credential = subprocess.run(['security', 'find-generic-password', '-s', credential_service(original), '-w'], capture_output=True)
            assert credential.returncode == 0, 'Matching authorized Claude clone credential is unavailable'
            assert 'claudeAiOauth' in json.loads(credential.stdout)
            target = profile / '.credentials.json'
            target.write_bytes(credential.stdout.strip())
            target.chmod(0o600)
            # Claude may migrate the fallback file into its own path-specific
            # Keychain entry. Cleanup removes only this previously absent entry.
            staged_credentials.append(service)
        return profile

    def call(method, params=None):
        return request(socket_path, method, params)

    def ax(operation='inspect', **fields):
        if console_locked(): raise RuntimeError('Mac locked during the native check; unlock it before retrying')
        result = subprocess.run([str(helper)], input=json.dumps({'pid': pid, 'operation': operation, **fields}), capture_output=True, text=True, check=True)
        value = json.loads(result.stdout)
        if isinstance(value, dict): assert value.get('performed'), value
        return value

    def control(identifier=None, title=None):
        return next((c for c in ax() if (c['identifier'] == identifier if identifier else c['role'] == 'AXButton' and title in [c['title'], c['label']])), None)

    def select_profile(item):
        ax('press', identifier='preset.edit-' + item['presetID'])
        wait(lambda: control(identifier='preset.choose-configuration-directory'), 'preset editor')
        time.sleep(.3)
        button = control(identifier='preset.choose-configuration-directory')
        ax('click', identifier=button['identifier'], x=button['frame']['width'] / 2, y=button['frame']['height'] / 2)
        wait(lambda: control(title='Open'), 'native profile folder panel')
        field = next(c for c in ax() if c['role'] == 'AXTextField' and c['identifier'] and not c['identifier'].startswith('preset.'))
        ax('click', identifier=field['identifier'], x=field['frame']['width'] / 2, y=field['frame']['height'] / 2)
        ax('key', identifier=field['identifier'], keyCode=5, modifiers=['command', 'shift'], systemKeyboard=True)
        wait(lambda: control(identifier='PathTextField'), 'Go to Folder')
        ax('typeText', identifier='PathTextField', value=str(item['profile']), systemKeyboard=True)
        ax('key', identifier='PathTextField', keyCode=36, systemKeyboard=True)
        wait(lambda: not control(identifier='GoToWindow'), 'profile folder selected')
        ax('press', title='Open')
        wait(lambda: not control(title='Open'), 'native folder panel closed')
        assert control(identifier='preset.configuration-directory')['value'] == str(item['profile'])
        ax('press', title='Save Preset')
        wait(lambda: not control(identifier='preset.name'), 'preset saved')

    def open_app():
        global pid
        assert not console_locked(), 'Unlock the Mac before opening the private test app'
        subprocess.run(['/usr/bin/open', '-n', str(app)], check=True)
        report = json.loads(subprocess.check_output([str(repository / '.build/app-window-probe'), str(app)], text=True))
        pid = report['pid']
        assert report['visibleWindows'] and report['finishedLaunching']
        wait(lambda: call('status').get('mcpEndpoint'), 'registered private runtime')
        return report

    def quit_app():
        global pid
        old = pid
        ax('press', title='Quit Chauffeur', role='AXMenuItem', includeMenus=True)
        wait(lambda: subprocess.run(['/bin/kill', '-0', str(old)], capture_output=True).returncode != 0, 'normal UI Quit')
        pid = None

    def runtime_pid():
        state = job_info(label)
        (artifacts / 'launchd.private.txt').write_text(state.stdout)
        match = re.search(r'^\s*pid = (\d+)$', state.stdout, re.M)
        if not match: return None
        value = int(match[1])
        assert pid_path(value) == binaries / 'ChauffeurRuntime', 'launchd selected another helper'
        return value

    def current(item):
        return next(s for s in call('snapshot')['sessions'] if s['id'] == item['session']['id'])

    def capture(stage):
        (artifacts / (stage + '-snapshot.private.json')).write_text(json.dumps(call('snapshot'), indent=2))
        (artifacts / (stage + '-controls.private.json')).write_text(json.dumps(ax(), indent=2))

    def unchanged():
        for item in sessions:
            value, original = current(item), item['session']
            assert value['processID'] == original['processID']
            assert value['terminalIdentity'] == original['terminalIdentity']
            assert value['launch'] == original['launch']
            assert value['state'] not in ['exited', 'failed', 'interrupted']
            os.kill(value['processID'], 0)
            if item.get('conversationID'):
                assert value['nativeConversationID'] == item['conversationID']
        return True

    def screen(item):
        identifier = 'terminal-' + item['session']['id']
        view = next((c for c in ax() if c['identifier'] == identifier), None)
        text = view['value'] if view else ''
        (artifacts / (item['kind'] + '-terminal.private.txt')).write_text(text)
        return text

    def key(item, code):
        ax('key', identifier='terminal-' + item['session']['id'], windowIdentifier='project-' + item['projectID'], keyCode=code)

    def ready(item):
        text = screen(item)
        assert current(item)['state'] not in ['exited', 'failed', 'interrupted']
        if ''.join(str(item['checkout']).split()) in ''.join(text.split()):
            if item['kind'] == 'codex' and 'Do you trust' in text and 'Yes, continue' in text:
                key(item, 36); return False
            if item['kind'] == 'claude' and 'Yes, I trust this folder' in text:
                if '❯ No, exit' in text: key(item, 125)
                elif '❯ Yes, I trust this folder' in text: key(item, 36)
                else: raise AssertionError('Unexpected trust selection')
                return False
        if item['kind'] == 'codex':
            return 'Ask Codex to do anything' in text and 'loading' not in text and 'Do you trust' not in text
        return bool(re.search(r'^❯\s*(Try |$)', text, re.M)) and 'connecting' not in text.lower() and 'Yes, I trust' not in text

    def reply(item, stage):
        prefix = 'SERVICE_' + stage + '_'
        marker = prefix + item['word']
        task = 'Do not use tools, read files, or run commands. '
        if stage == 'READY':
            task += 'Remember the service check word ' + item['word'] + '. Reply only ' + prefix + ' immediately followed by that word.'
        else:
            task += 'Reply only ' + prefix + ' immediately followed by the service check word from my first message.'
        assert marker not in task
        ax('insertText', identifier='terminal-' + item['session']['id'], windowIdentifier='project-' + item['projectID'], value=task)
        time.sleep(.5); key(item, 36)
        wait(lambda: re.search(r'^\s*[●•⏺]?\s*' + re.escape(marker) + r'\s*$', screen(item), re.M)
            and current(item)['state'] == 'turnFinished', item['kind'] + ' reply after ' + stage, 180)
        item['conversationID'] = current(item)['nativeConversationID']
        assert item['conversationID']
        (artifacts / (item['kind'] + '-' + stage.lower() + '.private.txt')).write_text(screen(item))
        unchanged()

    def cleanup():
        global pid
        if sleep_observer is not None:
            if sleep_observer.poll() is None:
                sleep_observer.terminate()
            sleep_observer.wait(timeout=10)
        if pid:
            try: quit_app()
            except Exception:
                try: os.kill(pid, 15)
                except ProcessLookupError: pass
                pid = None
        for item in sessions:
            try: call('stop', {'sessionID': item['session']['id'], 'force': True})
            except Exception: pass
        cleanup_dir = artifacts / 'cleanup'
        cleanup_dir.mkdir(exist_ok=True, mode=0o700)
        report = cleanup_dir / 'service-probe.json'
        report.unlink(missing_ok=True)
        environment = dict(os.environ)
        for name in list(environment):
            if name.startswith('CHAUFFEUR_'): del environment[name]
        environment.update(CHAUFFEUR_SERVICE_PROBE_DIR=str(cleanup_dir), CHAUFFEUR_SERVICE_PROBE_ACTION='unregister', CHAUFFEUR_SERVICE_PROBE_SOCKET=str(socket_path))
        with (cleanup_dir / 'app.private.log').open('w') as log:
            process = subprocess.Popen([str(binaries / 'Chauffeur')], env=environment, stdout=log, stderr=log)
            try: process.wait(timeout=45)
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=5)
        subprocess.run(['tmux', '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        for service in staged_credentials:
            subprocess.run(['security', 'delete-generic-password', '-s', service], capture_output=True)
        if job_info(label).returncode == 0:
            # Only this uniquely named fixture job; never the default service.
            subprocess.run(['launchctl', 'bootout', job], capture_output=True)
        wait(lambda: job_info(label).returncode != 0, 'private job removed')
        assert report.exists(), 'Service unregister report missing'
        result = json.loads(report.read_text())
        assert result['status'] == 'notRegistered' and result.get('error') is None, 'Private service unregister failed'
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
        summary['privateServiceUnregistered'] = True

    try:
        open_app()
        first_runtime = call('status')
        assert first_runtime['liveSessions'] == 0 and not call('snapshot')['sessions']
        first_runtime_pid = wait(runtime_pid, 'launchd helper process')
        summary['nativePrivateRegistration'] = True
        quit_app()
        assert call('status')['runtimeID'] == first_runtime['runtimeID']
        if not options.registration_only:
            set_id = uid()
            call('savePresetSet', {'record': {'id': set_id, 'name': 'Native Service Fixture', 'revision': 1, 'archived': False}})
            prepared = []
            for kind in ['codex', 'claude']:
                checkout = root / (kind + ' repository'); checkout.mkdir()
                subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
                preset_id, project_id, folder_id, group_id = [uid() for _ in range(4)]
                now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
                executable = shutil.which(kind); assert executable
                profile = stage_profile(kind)
                arguments = ['-a', 'on-request', '-s', 'read-only'] if kind == 'codex' else ['--permission-mode', 'manual', '--tools', '']
                call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': kind.capitalize() + ' Private profile', 'kind': kind,
                    'executable': executable, 'configurationDirectory': str(profile), 'arguments': arguments, 'integration': 'unverified', 'archived': False}})
                call('saveProject', {'record': {'id': project_id, 'name': kind.capitalize() + ' Native Service', 'presetSetID': set_id,
                    'folders': [{'id': folder_id, 'name': 'Temporary repository', 'selectedPath': str(checkout), 'canonicalPath': str(checkout), 'availability': 'available', 'registered': True}],
                    'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
                    'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
                prepared.append({'kind': kind, 'projectID': project_id, 'presetID': preset_id, 'folderID': folder_id,
                    'groupID': group_id, 'checkout': checkout, 'profile': profile, 'word': uuid.uuid4().hex[:12].upper()})
            open_app()
            ax('press', title='Settings…', role='AXMenuItem', includeMenus=True)
            wait(lambda: control(title='Presets'), 'Settings presets')
            ax('press', title='Presets')
            for item in prepared:
                wait(lambda: control(identifier='preset.edit-' + item['presetID']), 'fixture preset')
                select_profile(item)
            quit_app()
            summary['nativeProfileFolderSelection'] = True
            for item in prepared:
                session = call('launch', {'projectID': item['projectID'], 'groupID': item['groupID'], 'presetID': item['presetID'], 'folderID': item['folderID'],
                    'additionalFolderIDs': [], 'title': item['kind'].capitalize() + ' Service Check', 'allowSharedCheckout': False, 'coordinationEnabled': True, 'retryKey': uid()})
                item['session'] = session
                sessions.append(item)
                call('saveWindow', {'record': {'id': item['projectID'], 'tabs': [session['id']], 'selectedSessionID': session['id'], 'sidebarVisible': True, 'wasOpen': True}})
            open_app()
            for item in sessions:
                wait(lambda: ready(item), item['kind'] + ' native prompt', 90)
                reply(item, 'READY')
            capture('initial')
            quit_app()
            assert runtime_pid() == first_runtime_pid
            unchanged()
            open_app()
            for item in sessions:
                wait(lambda: item['word'] in screen(item), item['kind'] + ' terminal after normal Quit')
            unchanged()
            quit_app()
            summary['normalQuitAndNativeReattach'] = True

        # Recovery is observed through launchd itself with the GUI closed.
        subprocess.run(['launchctl', 'kill', 'SIGKILL', job], capture_output=True, check=True)
        recovered = wait(lambda: (s if (s := call('status'))['runtimeID'] != first_runtime['runtimeID'] and s.get('mcpEndpoint') else None), 'launchd crash recovery')
        assert runtime_pid() != first_runtime_pid
        assert recovered['mcpEndpoint'] == first_runtime['mcpEndpoint']
        unchanged()
        open_app()
        for item in sessions: reply(item, 'AFTER_CRASH')
        capture('recovered')
        summary['launchdCrashRecovery'] = True

        ax('press', title='Settings…', role='AXMenuItem', includeMenus=True)
        wait(lambda: any(c['role'] == 'AXButton' and c['title'] == 'Runtime' for c in ax()), 'Settings tabs')
        ax('press', title='Runtime', role='AXButton')
        wait(lambda: any(c['role'] == 'AXButton' and 'Restart Service' in [c['title'], c['label']] and c['enabled'] for c in ax()), 'native Restart Service button')
        ax('press', title='Restart Service', role='AXButton')
        restarted = wait(lambda: (s if (s := call('status'))['runtimeID'] != recovered['runtimeID'] and s.get('mcpEndpoint') else None), 'native service restart')
        assert restarted['mcpEndpoint'] == first_runtime['mcpEndpoint']
        unchanged()
        for item in sessions: reply(item, 'AFTER_RESTART')
        capture('restarted')
        summary['nativeSettingsServiceRestart'] = True
        quit_app()

        for name in ['ChauffeurRuntime', 'chauffeurctl']:
            temporary = binaries / (name + '.replacement')
            shutil.copy2(source / 'Contents/MacOS' / name, temporary)
            os.replace(temporary, binaries / name)
        assert hashlib.sha256((binaries / 'ChauffeurRuntime').read_bytes()).hexdigest() != release_hash
        sign_app()
        open_app()
        updated = wait(lambda: (s if (s := call('status'))['runtimeID'] != restarted['runtimeID'] and s.get('mcpEndpoint') else None), 'updated helper registration')
        assert updated['mcpEndpoint'] == first_runtime['mcpEndpoint']
        runtime_pid(); unchanged()
        for item in sessions: reply(item, 'AFTER_UPDATE')
        capture('updated')
        summary['bundledHelperReplacement'] = True
        if options.sleep_wake:
            power_log = artifacts / 'sleep-wake.jsonl'
            power_log.unlink(missing_ok=True)
            sleep_observer = subprocess.Popen([str(repository / '.build/system-sleep-observer'), str(power_log)])

            def power_events():
                assert sleep_observer.poll() is None, 'System sleep observer exited'
                try:
                    return [json.loads(line) for line in power_log.read_text().splitlines()]
                except FileNotFoundError:
                    return []

            wait(lambda: any(e['event'] == 'observerReady' for e in power_events()), 'system sleep observer')
            capture('before-sleep')
            print('READY_FOR_SLEEP: Both private agents have replied after service recovery. Sleep the Mac, then wake and unlock it.', flush=True)

            def completed_sleep():
                events = [e['event'] for e in power_events()]
                return 'willSleep' in events and 'didWake' in events[events.index('willSleep') + 1:]

            wait(completed_sleep, 'user-initiated system sleep/wake', 7200)
            wait(lambda: not console_locked(), 'console unlock after wake', 7200)
            wait(lambda: call('status').get('mcpEndpoint'), 'runtime after system wake')
            unchanged()
            for item in sessions:
                wait(lambda: item['word'] in screen(item), item['kind'] + ' terminal after wake')
                reply(item, 'AFTER_WAKE')
            capture('after-wake')
            summary['userInitiatedSleepWake'] = True
            summary['nativeRepliesAfterWake'] = True
            summary['systemPowerEvents'] = power_events()
        summary['sameProcessesAndConversations'] = bool(sessions)
        summary['nativeProviderRepliesAfterRecovery'] = bool(sessions)
        summary['versions'] = {item['kind']: item['session']['launch']['executableVersion'] for item in sessions}
        events = [json.loads(line) for line in (root / 'runtime/logs/runtime.jsonl').read_text().splitlines()]
        assert not any(event['event'] == 'toolCalled' for event in events), 'Unexpected tool use'
        (artifacts / 'events.private.json').write_text(json.dumps(events, indent=2))
    except BaseException:
        try: (artifacts / 'failed-snapshot.private.json').write_text(json.dumps(call('snapshot'), indent=2))
        except Exception: pass
        if pid:
            try: (artifacts / 'failed-controls.private.json').write_text(json.dumps(ax(), indent=2))
            except Exception: pass
        raise
    finally:
        cleanup()

default_after = request(default_socket, 'snapshot')
assert default_after['health']['runtimeID'] == default_before['health']['runtimeID']
for key in ['sessions', 'messages']:
    assert default_before[key] == default_after[key]
for key in ['presets', 'presetSets']:
    assert default_before['store'][key] == default_after['store'][key]
assert hashlib.sha256((release / 'Contents/MacOS/ChauffeurRuntime').read_bytes()).hexdigest() == release_hash
summary.update(passed=True, defaultServiceAndRecordsUnchanged=True, releaseUnchanged=True,
    scope='private SMAppService job; ' + ('user-initiated sleep/wake; ' if options.sleep_wake else 'no sleep; ')
        + 'no permission changes, tools, messages or delegation')
(artifacts / 'summary.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary, indent=2), flush=True)
