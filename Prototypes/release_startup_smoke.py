#!/usr/bin/env python3
"""Cold-launch the signed Release UI in an isolated bundle and runtime.

Checks actual GUI startup, not only signatures or a command's exit status.
No provider account, session, default runtime, or user preferences are changed.
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

repository = Path(__file__).resolve().parents[1]
source = repository / 'build/Build/Products/Release/Chauffeur.app'
artifacts = repository / '.build/release-startup-artifacts'
artifacts.mkdir(exist_ok=True)
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
    try:
        for _ in range(100):
            if socket_path.exists(): break
            assert runtime.poll() is None, 'Fixture runtime exited'
            time.sleep(0.1)
        assert socket_path.exists(), 'Fixture runtime did not start'
        subprocess.run(['/usr/bin/open', '-n', str(app)], check=True)
        probe = subprocess.run(['swift', str(repository / 'Prototypes/app_window_probe.swift'), str(app)], capture_output=True, text=True, timeout=45)
        (artifacts / 'probe.log').write_text(probe.stderr)
        report = json.loads(probe.stdout)
        (artifacts / 'windows.json').write_text(json.dumps(report, indent=2))
        assert probe.returncode == 0, 'Release did not finish launching with a visible window'
        window = max(report['visibleWindows'], key=lambda item: item['bounds'].get('Width', 0) * item['bounds'].get('Height', 0))
        subprocess.run(['/usr/sbin/screencapture', '-x', '-l', str(window['id']), str(artifacts / 'window.png')], check=True)
        # Catch an app that creates a window and immediately exits.
        time.sleep(2)
        os.kill(report['pid'], 0)
        print(json.dumps({'passed': True, 'releaseGUIStarted': True, 'visibleWindowCount': len(report['visibleWindows']), 'separateLauncherExecutable': True, 'isolatedRuntime': True}, indent=2))
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
