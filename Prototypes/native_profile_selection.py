#!/usr/bin/env python3
"""Check two authorized profiles in two native Release project windows.

Uses existing private clones, temporary repositories and an isolated runtime.
Reads native account diagnostics without model prompts. Raw process environments
and credentials are never written or printed. Account displays stay private.
"""
import argparse
import base64
import ctypes
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import time
import uuid

os.umask(0o077)
repository = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kind', choices=['codex', 'claude'], required=True)
options = parser.parse_args()
executable = shutil.which(options.kind)
assert executable
profiles = [(repository / '.local/profile-isolation' / (options.kind + '-' + label)).resolve(strict=True) for label in ['a', 'b']]
artifacts = repository / '.local' / ('profiles-native-' + options.kind)
artifacts.mkdir(exist_ok=True, mode=0o700)
(artifacts / 'summary.json').unlink(missing_ok=True)
helper = repository / '.build/app-accessibility-probe'
subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(helper)], check=True)


def uid():
    return str(uuid.uuid4()).upper()


def wait(probe, label, timeout=90):
    deadline, printed = time.monotonic() + timeout, 0
    while time.monotonic() < deadline:
        value = probe()
        if value: return value
        if time.monotonic() - printed > 10:
            print('Waiting:', label, flush=True); printed = time.monotonic()
        time.sleep(.2)
    raise AssertionError('Timed out: ' + label)


def process_indicators(pid, profile):
    libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t()
    assert libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) == 0
    assert 4 < size.value <= 2 * 1024 * 1024
    buffer = ctypes.create_string_buffer(size.value)
    assert libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) == 0
    raw = buffer.raw[:size.value]
    argc, = struct.unpack_from('=i', raw)
    assert 0 < argc < 4096
    cursor = raw.index(b'\0', 4) + 1
    while raw[cursor] == 0: cursor += 1
    for _ in range(argc): cursor = raw.index(b'\0', cursor) + 1
    entries = raw[cursor:].split(b'\0')
    prefix = b'CODEX_HOME=' if options.kind == 'codex' else b'CLAUDE_CONFIG_DIR='
    selected = [entry.split(b'=', 1)[1] for entry in entries if entry.startswith(prefix)]
    routed = any(entry.startswith(prefix) for entry in entries for prefix in [b'ANTHROPIC_API_KEY=', b'ANTHROPIC_AUTH_TOKEN=', b'OPENAI_API_KEY='])
    return {'configurationPathMatches': selected == [os.fsencode(profile)], 'inheritedProviderCredentialsAbsent': not routed}


with tempfile.TemporaryDirectory(prefix='chauffeur-native-profiles-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Release/Chauffeur.app', app, symlinks=True)
    identifier = 'dev.chauffeur.profiles-probe.' + uuid.uuid4().hex
    socket_path = root / 'runtime/runtime.sock'
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info['CFBundleIdentifier'] = identifier
    info['LSEnvironment'] = {'CHAUFFEUR_SOCKET': str(socket_path)}
    plist.write_bytes(plistlib.dumps(info))
    with (artifacts / 'sign.log').open('w') as log:
        subprocess.run(['codesign', '--force', '--sign', 'Developer ID Application: Leonardo Lobato',
                        '--preserve-metadata=entitlements,flags,runtime', str(app)], stdout=log, stderr=log, check=True)
    binaries = app / 'Contents/MacOS'
    runtime_log = (artifacts / 'runtime.private.log').open('w')
    environment = dict(os.environ, ANTHROPIC_API_KEY='invalid-fixture-anthropic',
                       ANTHROPIC_AUTH_TOKEN='invalid-fixture-token', OPENAI_API_KEY='invalid-fixture-openai')
    runtime = subprocess.Popen([str(binaries / 'ChauffeurRuntime'), '--data-dir', str(root)],
                               env=environment, stdout=runtime_log, stderr=runtime_log)
    pid, sessions, expected_accounts, prepared = None, [], [], []

    def call(method, params=None):
        return json.loads(subprocess.check_output([str(binaries / 'chauffeurctl'), 'request', method,
            json.dumps(params or {}), '--socket', str(socket_path)], text=True))

    def ax(operation='inspect', **fields):
        result = json.loads(subprocess.run([str(helper)], input=json.dumps({'pid': pid, 'operation': operation, **fields}),
                                          capture_output=True, text=True, check=True).stdout)
        if isinstance(result, dict): assert result.get('performed'), result
        return result

    def screen(session):
        control = next((c for c in ax(windowIdentifier='project-' + session['projectID']) if c['identifier'] == 'terminal-' + session['id']), None)
        return control['value'] if control else ''

    def key(session, code):
        ax('key', identifier='terminal-' + session['id'], windowIdentifier='project-' + session['projectID'], keyCode=code)

    def ready(session, checkout):
        text = screen(session)
        if ''.join(str(checkout).split()) in ''.join(text.split()):
            if options.kind == 'codex' and 'Do you trust' in text and 'Yes, continue' in text:
                key(session, 36); return False
            if options.kind == 'claude' and 'Yes, I trust this folder' in text:
                if '❯ No, exit' in text: key(session, 125)
                elif '❯ Yes, I trust this folder' in text: key(session, 36)
                else: raise AssertionError('Unexpected trust selection')
                return False
        if options.kind == 'codex':
            return 'Ask Codex to do anything' in text and 'loading' not in text and 'Do you trust' not in text
        return bool(re.search(r'^❯\s*(Try |$)', text, re.M)) and 'connecting' not in text.lower() and 'Yes, I trust' not in text

    try:
        wait(socket_path.exists, 'private runtime socket', 20)
        for label, profile in zip(['A', 'B'], profiles):
            checkout = root / ('repository-' + label); checkout.mkdir()
            subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
            env = {k: v for k, v in os.environ.items() if not k.startswith(('CODEX_', 'CLAUDE_', 'CLAUDECODE', 'OPENAI_', 'ANTHROPIC_', 'CHAUFFEUR_', 'AWS_', 'GOOGLE_', 'VERTEX_', 'BEDROCK_'))}
            env['CODEX_HOME' if options.kind == 'codex' else 'CLAUDE_CONFIG_DIR'] = str(profile)
            if options.kind == 'codex':
                diagnostic = json.loads(subprocess.check_output([executable, 'doctor', '--json'], env=env, cwd=checkout, text=True, timeout=30))
                assert Path(diagnostic['checks']['config.load']['details']['CODEX_HOME']).resolve() == profile
                (artifacts / (label + '-doctor.private.json')).write_text(json.dumps(diagnostic, indent=2))
                # Compare the native display to the clone's selected login in
                # memory; never emit or persist its JWT or credential contents.
                auth = json.loads((profile / 'auth.json').read_text())
                payload = auth['tokens']['id_token'].split('.')[1]
                claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
                email = claims.get('email') or claims.get('https://api.openai.com/profile', {}).get('email')
                context = auth['tokens']['account_id']
                assert email and context
                expected = {'email': email, 'context': context}
                del auth, claims, payload
            else:
                expected = json.loads(subprocess.check_output([executable, 'auth', 'status', '--json'], env=env, cwd=checkout, text=True, timeout=30))
                assert expected['loggedIn'] and Path(expected['configDirectory']).resolve() == profile
                assert expected.get('email') and expected.get('orgName')
            expected_accounts.append(expected)
            set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
            now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
            call('savePresetSet', {'record': {'id': set_id, 'name': 'Profile ' + label, 'revision': 1, 'archived': False}})
            arguments = ['-a', 'on-request', '-s', 'read-only'] if options.kind == 'codex' else ['--permission-mode', 'manual', '--tools', '']
            call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Profile ' + label, 'kind': options.kind,
                'executable': executable, 'configurationDirectory': str(profile), 'arguments': arguments, 'integration': 'unverified', 'archived': False}})
            call('saveProject', {'record': {'id': project_id, 'name': 'Native Profile ' + label, 'presetSetID': set_id,
                'folders': [{'id': folder_id, 'name': 'Repository ' + label, 'selectedPath': str(checkout), 'canonicalPath': str(checkout), 'availability': 'available', 'registered': True}],
                'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
                'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
            session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id, 'folderID': folder_id,
                'additionalFolderIDs': [], 'title': 'Profile ' + label, 'allowSharedCheckout': False, 'coordinationEnabled': False, 'retryKey': uid()})
            sessions.append(session)
            call('saveWindow', {'record': {'id': project_id, 'tabs': [session['id']], 'selectedSessionID': session['id'], 'sidebarVisible': True, 'wasOpen': True}})
            prepared.append((session, checkout, label, profile, expected))
        # Finish external fixture writes before the UI starts owning layouts.
        # Concurrent API writes correctly produce stale-layout conflicts.
        for session, checkout, label, profile, expected in prepared:
            project_id = session['projectID']
            subprocess.run([str(binaries / 'chauffeur-launcher'), str(checkout)], capture_output=True, check=True)
            report = json.loads(subprocess.check_output(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], text=True))
            pid = report['pid']
            # A warm launch can report the existing A window before the folder
            # route has created B. Wait for this exact native project window.
            wait(lambda: any(c['role'] == 'AXWindow' and c['identifier'] == 'project-' + project_id for c in ax()), 'project window ' + label, 30)
            wait(lambda: ready(session, checkout), 'native ' + options.kind + ' profile ' + label)
            assert all(process_indicators(session['processID'], profile).values())
            ax('insertText', identifier='terminal-' + session['id'], windowIdentifier='project-' + project_id, value='/status')
            time.sleep(.6); key(session, 36)
            text = wait(lambda: (s if (s := screen(session)) and expected['email'] in ''.join(s.split()) else None), 'native account display ' + label)
            if options.kind == 'claude':
                assert ''.join(expected['orgName'].split()) in ''.join(text.split())
                assert session['nativeConversationID'] in text
            (artifacts / (label + '-status.private.txt')).write_text(text)
            print('Native account and process directory match profile', label, flush=True)
        report = json.loads(subprocess.check_output(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], text=True))
        assert len(report['visibleWindows']) == 2
        for session, profile in zip(sessions, profiles):
            os.kill(session['processID'], 0)
            assert all(process_indicators(session['processID'], profile).values())
            assert session['launch']['configurationPath'] == str(profile)
        snapshot = call('snapshot')
        assert len(snapshot['sessions']) == 2
        assert all(s['state'] == 'activityUnknown' for s in snapshot['sessions'])
        contexts = [a['context'] if options.kind == 'codex' else (a['email'], a.get('orgId')) for a in expected_accounts]
        summary = {'passed': True, 'kind': options.kind, 'version': sessions[0]['launch']['executableVersion'],
            'twoConcurrentNativeProjectWindows': True, 'nativeAccountDisplaysMatch': True,
            'effectiveChildDirectoriesMatch': True, 'inheritedProviderCredentialsAbsent': True,
            'basicModeReportsActivityUnknown': True, 'distinctAccountContexts': len(set(contexts)) == 2,
            'noModelPromptsSent': True}
        (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
    except BaseException:
        if pid:
            try: (artifacts / 'failed-controls.private.json').write_text(json.dumps(ax(), indent=2))
            except Exception: pass
        raise
    finally:
        if pid:
            try: os.kill(pid, 15)
            except ProcessLookupError: pass
        for session in sessions:
            try: call('stop', {'sessionID': session['id'], 'force': True})
            except Exception: pass
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        subprocess.run(['tmux', '-S', str(root / 'runtime/tmux.sock'), 'kill-server'], capture_output=True)
        runtime_log.close()
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
