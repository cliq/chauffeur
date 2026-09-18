#!/usr/bin/env python3
"""Verify service relocation and build identity using a private signed app/job.

Uses empty temporary stores. Does not register the user's Debug/Release jobs,
launch provider sessions, or change the installed /Applications app.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import uuid

repository = Path(__file__).resolve().parents[1]
products = repository / 'build/Build/Products'
debug = products / 'Debug/Chauffeur Debug.app'
release = Path(os.environ.get('CHAUFFEUR_TEST_RELEASE_APP', products / 'Release/Chauffeur.app'))
artifacts = repository / '.local/service-installation-artifacts'
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
signing = (products / 'Debug/Chauffeur.signing-identity').read_text().strip()
assert signing and signing != '-', 'This native service test requires the signed Debug build'


def plist(app, relative):
    return plistlib.loads((app / relative).read_bytes())


debug_info = plist(debug, 'Contents/Info.plist')
release_info = plist(release, 'Contents/Info.plist')
assert debug_info['CFBundleIdentifier'] != release_info['CFBundleIdentifier']
assert debug_info['CFBundleDisplayName'] == 'Chauffeur Debug'
assert release_info['CFBundleDisplayName'] == 'Chauffeur'
launch_plist = 'Contents/Library/LaunchAgents/dev.chauffeur.runtime.plist'
assert plist(debug, launch_plist)['Label'] == 'dev.chauffeur.debug.runtime'
assert plist(release, launch_plist)['Label'] == 'dev.chauffeur.runtime'
notification_plist = 'Contents/Library/ChauffeurNotifications.app/Contents/Info.plist'
assert plist(debug, notification_plist)['CFBundleIdentifier'] != plist(release, notification_plist)['CFBundleIdentifier']
assert debug_info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['chauffeur-debug']
assert release_info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['chauffeur']


def call(socket_path):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(socket_path))
        data = json.dumps({'version': 1, 'id': str(uuid.uuid4()), 'method': 'status', 'params': {}}).encode()
        connection.sendall(struct.pack('!I', len(data)) + data)

        def exact(count):
            result = bytearray()
            while len(result) < count:
                chunk = connection.recv(count - len(result))
                if not chunk:
                    raise OSError('Runtime disconnected')
                result.extend(chunk)
            return result

        count, = struct.unpack('!I', exact(4))
        assert count <= 8 * 1024 * 1024
        response = json.loads(exact(count))
        assert not response.get('error'), response
        return response['result']


def wait_ready(socket_path):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            value = call(socket_path)
            if value.get('mcpEndpoint'):
                return value
        except OSError:
            pass
        time.sleep(0.1)
    raise AssertionError('Runtime did not become ready')


with tempfile.TemporaryDirectory(prefix='chauffeur-install-', dir='/tmp') as temporary:
    root = Path(temporary).resolve()
    data = root / 'data'
    data.mkdir()
    socket_path = data / 'runtime/runtime.sock'
    suffix = uuid.uuid4().hex
    identifier = 'dev.cliq.chauffeur.installation-test.' + suffix
    label = 'dev.chauffeur.debug.runtime.test.' + suffix
    job = f'gui/{os.getuid()}/{label}'
    app = root / 'original/Chauffeur Debug.app'
    shutil.copytree(debug, app, symlinks=True)
    info = plist(app, 'Contents/Info.plist')
    info['CFBundleIdentifier'] = identifier
    info['CFBundleURLTypes'] = []
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    config = plist(app, launch_plist)
    config['Label'] = label
    config['ProgramArguments'] = ['ChauffeurRuntime', '--data-dir', str(data)]
    (app / launch_plist).write_bytes(plistlib.dumps(config))
    subprocess.run(['codesign', '--force', '--sign', signing, '--preserve-metadata=entitlements,flags,runtime', str(app)], check=True)

    def probe(name, connection=socket_path, unregister=False, expected_online=True, stop=False, restart=False):
        directory = root / 'probe-reports' / name
        directory.mkdir(parents=True, exist_ok=True)
        report = directory / 'service-probe.json'
        report.unlink(missing_ok=True)
        environment = {key: value for key, value in os.environ.items() if not key.startswith('CHAUFFEUR_')}
        environment.update(CHAUFFEUR_SERVICE_PROBE_DIR=str(directory), CHAUFFEUR_SERVICE_PROBE_SOCKET=str(connection))
        if unregister:
            environment['CHAUFFEUR_SERVICE_PROBE_ACTION'] = 'unregister'
        if stop:
            environment['CHAUFFEUR_SERVICE_PROBE_ACTION'] = 'stop'
        if restart:
            environment['CHAUFFEUR_SERVICE_PROBE_RESTART'] = '1'
        with (directory / 'app.log').open('w') as log:
            process = subprocess.Popen([str(app / 'Contents/MacOS/Chauffeur')], env=environment, cwd=root, stdout=log, stderr=log)
            try:
                assert process.wait(timeout=40) == 0, f'{name}: app failed'
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
        shutil.copytree(directory, artifacts / name, dirs_exist_ok=True)
        result = json.loads(report.read_text())
        assert result['registrationError'] is None and result['error'] is None, result
        if not unregister:
            assert result['online'] == expected_online, result
            assert result['runtimeVerified'] == expected_online, result
        print(name + ': passed', flush=True)
        return result

    release_process = None
    release_log = None
    try:
        initial = probe('initial')
        assert initial['health']['identity']['build'] == 'Debug'
        assert initial['health']['identity']['executablePath'] == str(app / 'Contents/MacOS/ChauffeurRuntime')
        assert initial['health']['identity']['dataRoot'] == str(data)
        # No code changes: only move the app, exactly as a Finder installation does.
        moved = root / 'Applications/Chauffeur Debug.app'
        moved.parent.mkdir()
        shutil.move(str(app), str(moved))
        app = moved
        relocated = probe('relocated')
        assert relocated['health']['identity']['executablePath'] == str(app / 'Contents/MacOS/ChauffeurRuntime')
        assert relocated['health']['runtimeID'] != initial['health']['runtimeID']
        assert relocated['health']['identity']['executableDigest'] == initial['health']['identity']['executableDigest']
        stable = probe('unchanged-relaunch')
        assert stable['health']['runtimeID'] == relocated['health']['runtimeID'], 'Unchanged app unnecessarily restarted its service'

        for attempt in range(2):
            restarted = probe(f'explicit-restart-{attempt + 1}', restart=True)
            assert restarted['health']['runtimeID'] != stable['health']['runtimeID'], 'Restart Service kept the old runtime instance'
            assert restarted['health']['pid'] != stable['health']['pid'], 'Restart Service kept the old process'
            assert restarted['health']['identity'] == stable['health']['identity']
            stable = restarted

        stopped = probe('stop', expected_online=False, stop=True)
        assert stopped['stopped'] and stopped['status'] == 'notRegistered', stopped
        assert subprocess.run(['launchctl', 'print', job], capture_output=True).returncode != 0
        resumed = probe('start-after-stop')
        assert resumed['health']['runtimeID'] != stable['health']['runtimeID']
        stable = resumed

        release_root = root / 'release-data'
        release_log = (artifacts / 'release-runtime.log').open('w')
        release_process = subprocess.Popen([str(release / 'Contents/MacOS/ChauffeurRuntime'), '--data-dir', str(release_root)], cwd=root, stdout=release_log, stderr=release_log)
        release_socket = release_root / 'runtime/runtime.sock'
        foreign = wait_ready(release_socket)
        assert foreign['identity']['build'] == 'Release'
        assert call(socket_path)['runtimeID'] == stable['health']['runtimeID']
        # The probe socket keeps registration enabled, unlike CHAUFFEUR_SOCKET.
        # Pointing it at Release must never mark the Debug app connected/verified.
        rejected = probe('reject-foreign-runtime', connection=release_socket, expected_online=False)
        assert 'different app build or location' in rejected['message'], rejected
        assert call(release_socket)['runtimeID'] == foreign['runtimeID'], 'Identity recovery changed the foreign runtime'
        summary = {'passed': True, 'separateBuildIdentities': True, 'moveRefreshesRegistration': True, 'unchangedLaunchKeepsRuntime': True, 'explicitRestartReplacesProcess': True, 'foreignRuntimeRejected': True, 'quitServiceStaysStopped': True, 'reopenStartsService': True}
        (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(json.dumps(summary, indent=2))
    finally:
        if release_process:
            release_process.terminate()
            try:
                release_process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                release_process.kill()
                release_process.wait()
        if release_log:
            release_log.close()
        probe('unregister', unregister=True)
        assert subprocess.run(['launchctl', 'print', job], capture_output=True).returncode != 0, 'Private job remains registered'
        subprocess.run(['defaults', 'delete', identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
