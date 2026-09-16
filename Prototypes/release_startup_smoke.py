#!/usr/bin/env python3
"""Cold-launch the signed Release UI in an isolated bundle and runtime.

Checks actual GUI startup, not only signatures or a command's exit status.
No provider account, session, default runtime, or user project is changed.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--native-controls', action='store_true', help='Also check window reopening, native diagnostics export, and normal Quit through existing Accessibility access')
options = parser.parse_args()

repository = Path(__file__).resolve().parents[1]
source = repository / 'build/Build/Products/Release/Chauffeur.app'
artifacts = repository / '.build/release-startup-artifacts'
artifacts.mkdir(exist_ok=True)
for name in ['summary.json', 'failed-controls.json']:
    (artifacts / name).unlink(missing_ok=True)
helper = repository / '.build/app-accessibility-probe'
if options.native_controls:
    subprocess.run(['swiftc', str(repository / 'Prototypes/app_accessibility_probe.swift'), '-o', str(helper)], check=True)
assert not (source / 'Contents/MacOS/Chauffeur').samefile(source / 'Contents/MacOS/chauffeur-launcher')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)

with tempfile.TemporaryDirectory(prefix='chauffeur-release-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    app = root / 'Chauffeur.app'
    shutil.copytree(source, app, symlinks=True)
    identifier = 'dev.chauffeur.release-probe.' + uuid.uuid4().hex
    socket_path = root / 'runtime/runtime.sock'
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info['CFBundleIdentifier'] = identifier
    info['LSEnvironment'] = {'CHAUFFEUR_SOCKET': str(socket_path)}
    plist.write_bytes(plistlib.dumps(info))
    signing = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True, check=True)
    identities = re.findall(r'^\s*\d+\) ([A-Fa-f0-9]+) "Developer ID Application: Leonardo Lobato \([^"]+"', signing.stdout, re.M)
    assert len(identities) == 1
    with (artifacts / 'sign.log').open('w') as log:
        subprocess.run(['codesign', '--force', '--sign', identities[0], '--preserve-metadata=entitlements,flags,runtime', str(app)], stdout=log, stderr=log, check=True)
    runtime_log = (artifacts / 'runtime.log').open('w')
    runtime = subprocess.Popen([str(app / 'Contents/MacOS/ChauffeurRuntime'), '--data-dir', str(root)], stdout=runtime_log, stderr=runtime_log)
    report = {}
    def wait_for(probe, description):
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            result = probe()
            if result:
                return result
            time.sleep(0.1)
        raise AssertionError('Timed out: ' + description)

    def ax(operation, **fields):
        result = subprocess.run([str(helper)], input=json.dumps({'pid': report['pid'], 'operation': operation, **fields}), capture_output=True, text=True, check=True)
        value = json.loads(result.stdout)
        if isinstance(value, dict):
            assert value.get('performed'), value
        return value

    def present(title, role='AXButton'):
        return any(c['role'] == role and title in [c['title'], c['label']] for c in ax('inspect'))

    def ready_window():
        probe = subprocess.run(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], capture_output=True, text=True, timeout=45)
        (artifacts / 'probe.log').write_text(probe.stderr)
        value = json.loads(probe.stdout)
        assert probe.returncode == 0, 'Release did not finish launching with a visible window'
        return value
    try:
        for _ in range(100):
            if socket_path.exists(): break
            assert runtime.poll() is None, 'Fixture runtime exited'
            time.sleep(0.1)
        assert socket_path.exists(), 'Fixture runtime did not start'
        subprocess.run(['/usr/bin/open', '-n', str(app)], check=True)
        report = ready_window()
        (artifacts / 'windows.json').write_text(json.dumps(report, indent=2))
        window = max(report['visibleWindows'], key=lambda item: item['bounds'].get('Width', 0) * item['bounds'].get('Height', 0))
        subprocess.run(['/usr/sbin/screencapture', '-x', '-l', str(window['id']), str(artifacts / 'window.png')], check=True)
        # Catch an app that creates a window and immediately exits.
        time.sleep(2)
        os.kill(report['pid'], 0)
        summary = {'passed': True, 'releaseGUIStarted': True, 'visibleWindowCount': len(report['visibleWindows']), 'separateLauncherExecutable': True, 'isolatedRuntime': True}
        if options.native_controls:
            original_pid = report['pid']
            ax('closeWindow', title='Welcome to Chauffeur', role='AXWindow')
            wait_for(lambda: not any(c['role'] == 'AXWindow' for c in ax('inspect')), 'all windows closed')
            subprocess.run(['/usr/bin/open', str(app)], check=True)
            report = ready_window()
            assert report['pid'] == original_pid, 'Reopening should use the running app'
            summary['reopenWithNoWindows'] = True
            ax('press', title='Settings…', role='AXMenuItem', includeMenus=True)
            wait_for(lambda: present('Runtime'), 'Settings tabs')
            ax('press', title='Runtime')
            wait_for(lambda: present('Export Diagnostics…'), 'Runtime settings')
            ax('press', title='Export Diagnostics…')
            wait_for(lambda: present('Cancel') and present('Save'), 'diagnostics save panel')
            (artifacts / 'save-panel.json').write_text(json.dumps(ax('inspect'), indent=2))
            ax('press', title='Cancel')
            wait_for(lambda: not present('Save'), 'save cancellation')
            assert not (root / 'diagnostics.json').exists()
            ax('press', title='Export Diagnostics…')
            wait_for(lambda: present('Save'), 'diagnostics save panel again')
            ax('typeText', identifier='saveAsNameTextField', value='diagnostics.json', systemKeyboard=True)
            wait_for(lambda: any(c['identifier'] == 'saveAsNameTextField' and c['value'] == 'diagnostics.json' for c in ax('inspect')), 'destination filename')
            ax('key', identifier='saveAsNameTextField', keyCode=5, modifiers=['command', 'shift'], systemKeyboard=True)
            wait_for(lambda: any(c['identifier'] == 'PathTextField' for c in ax('inspect')), 'Go to Folder')
            (artifacts / 'go-to-folder.json').write_text(json.dumps(ax('inspect'), indent=2))
            ax('typeText', identifier='PathTextField', value=str(root), systemKeyboard=True)
            wait_for(lambda: any(c['identifier'] == 'PathTextField' and c['value'] == str(root) for c in ax('inspect')), 'destination path')
            ax('key', identifier='PathTextField', keyCode=36, systemKeyboard=True)
            wait_for(lambda: not any(c['identifier'] == 'GoToWindow' for c in ax('inspect')), 'destination folder selected')
            ax('press', title='Save')
            destination = root / 'diagnostics.json'
            wait_for(destination.exists, 'diagnostics export')
            diagnostics = json.loads(destination.read_text())
            assert diagnostics['schemaVersion'] == 1
            assert diagnostics['observation'] == 'live'
            assert destination.stat().st_mode & 0o777 == 0o600
            summary['nativeDiagnosticsCancelAndSave'] = True
            ax('press', title='Quit Chauffeur', role='AXMenuItem', includeMenus=True)
            def quit_finished():
                try:
                    os.kill(original_pid, 0)
                    return False
                except ProcessLookupError:
                    return True
            wait_for(quit_finished, 'normal Quit')
            assert runtime.poll() is None
            subprocess.run(['/usr/bin/open', str(app)], check=True)
            report = ready_window()
            assert report['pid'] != original_pid
            assert runtime.poll() is None
            summary['quitAndColdRelaunch'] = True
        (artifacts / 'summary.json').write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2))
    except Exception:
        if options.native_controls and report.get('pid'):
            try:
                (artifacts / 'failed-controls.json').write_text(json.dumps(ax('inspect'), indent=2))
            except (OSError, subprocess.CalledProcessError, ValueError):
                pass
        raise
    finally:
        if report.get('pid'):
            try: os.kill(report['pid'], 15)
            except ProcessLookupError: pass
        runtime.terminate()
        try: runtime.wait(timeout=10)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        runtime_log.close()
        subprocess.run(['defaults', 'delete', identifier], capture_output=True)
