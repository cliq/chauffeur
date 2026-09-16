#!/usr/bin/env python3
"""Native terminal links and pointer input through macOS.

Uses an isolated signed Debug copy, temporary folder and a fixture CLI session.
No provider accounts, default runtime, real repositories or Release app writes.
"""
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
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
artifacts = repository / '.build/terminal-pointer-artifacts'
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

requests = set()
class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.add(self.path)
        body = b'<!doctype html><title>Chauffeur link check</title><h1>Terminal link opened</h1><p>This local fixture tab can be closed.</p>'
        self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *_):
        pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Page)
Thread(target=server.serve_forever, daemon=True).start()
origin = 'http://127.0.0.1:' + str(server.server_port)

with tempfile.TemporaryDirectory(prefix='chauffeur-terminal-pointer-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(repository / 'build/Build/Products/Debug/Chauffeur.app', app, symlinks=True)
    identifier = 'dev.chauffeur.terminal-pointer-probe.' + uuid.uuid4().hex
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
        return result

    def screenshot(name):
        # State publication precedes SwiftUI's next native layout/display pass.
        time.sleep(0.5)
        window = state()['sheetWindow'] or window_id
        assert window
        subprocess.run(['/usr/sbin/screencapture', '-x', '-l', str(window), str(artifacts / (name + '.png'))], check=True)

    try:
        wait_for(lambda: call('status'), 'runtime ready')
        repo = root / 'terminal repository'; repo.mkdir()
        input_log = root / 'pointer-input.bin'
        (root / 'pointer.json').write_text(json.dumps({'origin': origin, 'inputFile': str(input_log)}))
        cli = root / 'pointer-cli'
        cli.write_text('#!' + sys.executable + '\nimport runpy\nrunpy.run_path('
                       + repr(str(repository / 'Prototypes/pointer_cli.py')) + ', run_name="__main__")\n')
        cli.chmod(0o700)
        set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
        now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Controls fixture', 'revision': 1, 'archived': False}})
        call('savePreset', {'record': {'id': preset_id, 'setID': set_id, 'name': 'Fixture agent', 'kind': 'codex', 'executable': str(cli), 'configurationDirectory': str(root), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Terminal Pointer Fixture', 'presetSetID': set_id,
            'folders': [{'id': folder_id, 'name': 'Terminal repository', 'selectedPath': str(repo), 'canonicalPath': str(repo), 'availability': 'available', 'registered': True}],
            'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}],
            'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset_id,
            'folderID': folder_id, 'additionalFolderIDs': [], 'title': 'Pointer fixture',
            'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
        session_id = session['id']
        call('saveWindow', {'record': {'id': project_id, 'tabs': [session_id], 'selectedSessionID': session_id,
            'sidebarVisible': True, 'wasOpen': True}})
        subprocess.run([str(binary_dir / 'chauffeur-launcher'), str(repo)], capture_output=True, check=True)
        ready = wait_for(lambda: (s if (s := state())['online'] and s['ready'] else None), 'project window ready')
        app_pid = ready['processID']
        windows = json.loads(subprocess.check_output(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], text=True))
        window_id = max(windows['visibleWindows'], key=lambda w: w['bounds']['Width'])['id']
        terminal_id = 'terminal-' + session_id
        wait_for(lambda: (c if (c := control(terminal_id)) and 'Chauffeur pointer fixture' in c['value'] else None), 'fixture displayed')
        snapshot = call('terminalSnapshot', {'sessionID': session_id})
        frame = control(terminal_id)['frame']
        cell_width = (frame['width'] - 15) / snapshot['columns']
        cell_height = frame['height'] / snapshot['rows']
        def point(col, row):
            return {'x': (col + 0.5) * cell_width, 'y': (row + 0.5) * cell_height}
        def received():
            return input_log.read_bytes() if input_log.exists() else b''
        # Selection bypasses tmux/application mouse tracking with Shift.
        selection_start = received()
        ax('drag', terminal_id, **point(0, 5), endX=22 * cell_width, endY=5.5 * cell_height, modifiers=['shift'])
        wait_for(lambda: 'native mouse selection' in control(terminal_id)['selectedText'], 'mouse drag selected text')
        assert 'native mouse selection' in ax('copy', terminal_id)['text']
        assert received() == selection_start, 'Selecting text sent CLI input'
        # Command-click must invoke the real OS URL handler. Only a browser GET
        # to this unique local listener satisfies either link assertion.
        ax('click', terminal_id, **point(4, 2), modifiers=['command'])
        wait_for(lambda: '/implicit' in requests, 'implicit link opened in browser')
        ax('click', terminal_id, **point(4, 3), modifiers=['command'])
        wait_for(lambda: '/explicit' in requests, 'OSC 8 link opened in browser')
        ax('key', terminal_id, keyCode=97)  # F6
        wait_for(lambda: 'Mouse reporting enabled' in control(terminal_id)['value'], 'fixture tracking enabled')
        start = len(received())
        ax('click', terminal_id, **point(12, 11))
        wait_for(lambda: re.search(rb'\x1b\[<0;[0-9]+;[0-9]+M', received()[start:]), 'mouse press reached CLI')
        wait_for(lambda: re.search(rb'\x1b\[<0;[0-9]+;[0-9]+m', received()[start:]), 'mouse release reached CLI')
        ax('drag', terminal_id, **point(12, 11), endX=18.5 * cell_width, endY=11.5 * cell_height)
        wait_for(lambda: re.search(rb'\x1b\[<32;[0-9]+;[0-9]+M', received()[start:]), 'mouse drag reached CLI')
        ax('scroll', terminal_id, **point(12, 11), lines=3)
        wait_for(lambda: re.search(rb'\x1b\[<64;[0-9]+;[0-9]+M', received()[start:]), 'wheel up reached CLI')
        ax('scroll', terminal_id, **point(12, 11), lines=-3)
        wait_for(lambda: re.search(rb'\x1b\[<65;[0-9]+;[0-9]+M', received()[start:]), 'wheel down reached CLI')
        selection_start = received()
        ax('drag', terminal_id, **point(0, 5), endX=22 * cell_width, endY=5.5 * cell_height, modifiers=['shift'])
        wait_for(lambda: 'native mouse selection' in control(terminal_id)['selectedText'], 'selection while CLI tracks mouse')
        assert received() == selection_start, 'Shift-selection reached the mouse-tracking CLI'
        screenshot('pointer-selection')
        report = {'passed': True, 'commandClickImplicitURL': True, 'commandClickOSC8': True,
                  'nativeDragSelectionAndCopy': True, 'shiftSelectionBypassesMouseReporting': True,
                  'mousePressReleaseAndDrag': True, 'wheelUpDown': True, 'realOSURLHandler': True}
        (artifacts / 'summary.json').write_text(json.dumps(report, indent=2))
        print(json.dumps(report, indent=2))
    except BaseException:
        try:
            (artifacts / 'failed-controls.json').write_text(json.dumps(controls(), indent=2))
            (artifacts / 'input.bin').write_bytes(received())
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
        server.shutdown(); server.server_close()
