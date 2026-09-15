#!/usr/bin/env python3
"""Actual Debug app views with ten fake CLI sessions. No OS UI automation required.

The Debug-only in-app probe checks rendering, Unicode input, resize, and reattach.
The script checks normal UI quit/relaunch preserves processes and window state.
Real CLI/account/Spaces and keyboard accessibility acceptance remain separate gates.
"""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import uuid

repository = Path(__file__).resolve().parents[1]
app = repository / "build/Build/Products/Debug/Chauffeur.app/Contents/MacOS"
assert (app / "Chauffeur").exists(), "Run Scripts/build-app.sh first"
artifacts = repository / ".build/native-probe-artifacts"
artifacts.mkdir(exist_ok=True)

def uid():
    return str(uuid.uuid4()).upper()

def wait_for(probe, timeout=30):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            result = probe()
            if result:
                return result
        except (OSError, ValueError, AssertionError) as error:
            last = error
        time.sleep(0.1)
    raise AssertionError(f"Timed out: {last}")

with tempfile.TemporaryDirectory(prefix="chauffeur-native-", dir="/tmp") as directory:
    root = Path(directory)
    socket_path = str(root / "runtime/runtime.sock")
    log = open(artifacts / "runtime.log", "w")
    runtime = subprocess.Popen([str(app / "ChauffeurRuntime"), "--data-dir", str(root)], stdout=log, stderr=log)
    native = None
    def call(method, params=None):
        def exact(connection, count):
            data = bytearray()
            while len(data) < count:
                part = connection.recv(count - len(data))
                assert part, "Socket closed"
                data.extend(part)
            return data
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30); connection.connect(socket_path)
            data = json.dumps({"version": 1, "id": uid(), "method": method, "params": params or {}}).encode()
            connection.sendall(struct.pack("!I", len(data)) + data)
            count, = struct.unpack("!I", exact(connection, 4))
            assert count <= 8 * 1024 * 1024
            response = json.loads(exact(connection, count))
            assert not response.get("error"), response.get("error")
            return response.get("result")
    try:
        wait_for(lambda: call("status").get("mcpEndpoint"))
        config = root / "existing profile"; config.mkdir()
        set_id, preset_id = uid(), uid()
        call("savePresetSet", {"record": {"id": set_id, "name": "Fixture Personal", "revision": 1, "archived": False}})
        call("savePreset", {"record": {"id": preset_id, "setID": set_id, "name": "Fake Codex", "kind": "codex", "executable": str(repository / "Prototypes/fake_cli.py"), "configurationDirectory": str(config), "arguments": [], "integration": "unverified", "archived": False}})
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        for index in range(1, 5):
            project_id, group_id, folder_id = uid(), uid(), uid()
            checkout = root / f"repo-{index}"; checkout.mkdir()
            call("saveProject", {"record": {"id": project_id, "name": f"Window Fixture {index}", "presetSetID": set_id, "folders": [{"id": folder_id, "name": f"Repository {index}", "selectedPath": str(checkout), "canonicalPath": str(checkout.resolve()), "availability": "available", "registered": True}], "groups": [{"id": group_id, "name": "Default", "isDefault": True, "archived": False, "createdAt": now, "updatedAt": now}], "archived": False, "createdAt": now, "updatedAt": now, "lastOpenedAt": now}})
            tabs = []
            for number in range(1, 4 if index <= 2 else 3):
                session = call("launch", {"projectID": project_id, "groupID": group_id, "presetID": preset_id, "folderID": folder_id, "additionalFolderIDs": [], "title": f"Terminal {index}.{number}", "allowSharedCheckout": True, "coordinationEnabled": True, "retryKey": uid()})
                assert session["state"] == "activityUnknown", session
                tabs.append(session["id"])
            window = {"id": project_id, "tabs": tabs, "selectedSessionID": tabs[0], "sidebarVisible": True, "wasOpen": True}
            if index == 1:
                window["splitSessionID"] = tabs[-1]
            call("saveWindow", {"record": window})
        before = call("snapshot")
        reports = []
        for phase in [1, 2, 3]:
            environment = dict(os.environ, CHAUFFEUR_SOCKET=socket_path, CHAUFFEUR_NATIVE_PROBE_DIR=str(root), CHAUFFEUR_NATIVE_PROBE_PHASE=str(phase), CHAUFFEUR_NATIVE_PROBE_HOLD="1" if phase == 2 else "0")
            with open(artifacts / f"app-phase-{phase}.log", "w") as app_log:
                native = subprocess.Popen([str(app / "Chauffeur"), "-ApplePersistenceIgnoreState", "YES"], env=environment, stdout=app_log, stderr=app_log)
                def probe_report():
                    if native.poll() is not None and not (root / f"native-phase-{phase}.json").exists():
                        raise RuntimeError(f"Native app exited {native.returncode}; inspect {artifacts / f'app-phase-{phase}.log'}")
                    return json.loads((root / f"native-phase-{phase}.json").read_text())
                report = wait_for(probe_report, timeout=120)
                for result in root.glob(f"native-phase-{phase}.*"):
                    shutil.copy(result, artifacts / result.name)
                assert report["passed"], report
                if phase == 2:
                    native.kill()  # Force-quit only the UI, never the runtime.
                native.wait(timeout=15)
            for result in root.glob(f"native-phase-{phase}.*"):
                shutil.copy(result, artifacts / result.name)
            assert native.returncode == (-9 if phase == 2 else 0), native.returncode
            after = call("snapshot")
            (artifacts / f"window-states-phase-{phase}.json").write_text(json.dumps(after["store"]["windows"], indent=2))
            assert all(item["value"].get("frame") for item in after["store"]["windows"]), "A project frame was not persisted"
            first_project = min(after["store"]["projects"], key=lambda item: item["value"]["name"])["value"]["id"]
            first_window = next(item["value"] for item in after["store"]["windows"] if item["value"]["id"] == first_project)
            assert first_window["frame"] == report["frame"], "Saved frame differs from the native window"
            assert before["health"]["runtimeID"] == after["health"]["runtimeID"]
            assert {s["processID"] for s in before["sessions"]} == {s["processID"] for s in after["sessions"]}
            assert len([s for s in after["sessions"] if s["state"] == "activityUnknown"]) == 10
            assert len([w for w in after["store"]["windows"] if w["value"]["wasOpen"]]) == 4
            reports.append(report)
        assert len({report["frame"] for report in reports}) == 1, "Project frame did not restore"
        print(json.dumps({"nativeViewProbe": "pass", "phases": reports, "normalAndForceQuitRelaunch": "same ten processes; four windows restored", "artifacts": str(artifacts), "OSUIAutomationAndSpaces": "pending"}, indent=2))
    finally:
        for result in root.glob("native-phase-*.*"):
            shutil.copy(result, artifacts / result.name)
        try:
            terminal_inventory = subprocess.run([shutil.which("tmux"), "-S", str(root / "runtime/tmux.sock"), "list-panes", "-a", "-F", "#{session_name} #{pane_width}x#{pane_height} #{pane_dead}"], capture_output=True, text=True, timeout=5)
            (artifacts / "terminal-inventory.txt").write_text(terminal_inventory.stdout)
        except (OSError, subprocess.TimeoutExpired):
            pass
        if native and native.poll() is None:
            native.kill(); native.wait(timeout=5)
        try:
            for session in call("snapshot")["sessions"]:
                call("stop", {"sessionID": session["id"], "force": True})
        except (OSError, AssertionError):
            pass
        runtime.terminate()
        try:
            runtime.wait(timeout=5)
        except subprocess.TimeoutExpired:
            runtime.kill(); runtime.wait(timeout=5)
        subprocess.run([shutil.which("tmux"), "-S", str(root / "runtime/tmux.sock"), "kill-server"], capture_output=True)
        log.close()
