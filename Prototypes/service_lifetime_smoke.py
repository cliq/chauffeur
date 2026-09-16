#!/usr/bin/env python3
"""Exercise the actual per-user SMAppService job with an empty default store.

This changes the named Chauffeur test registration and unregisters it on exit.
Use runtime_smoke.py for checks that must not touch the default service.
"""
import argparse
import ctypes
import json
import os
import re
from pathlib import Path
import socket
import struct
import subprocess
import time
import uuid

repository = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--use-default-service", action="store_true", required=True)
parser.add_argument("--replace-test-registration", action="store_true",
                    help="Replace an existing empty-store Chauffeur test registration")
parser.add_argument("--app", type=Path, default=repository / "build/Build/Products/Debug/Chauffeur Debug.app")
parser.add_argument("--artifacts", type=Path, default=repository / ".build/service-lifetime-artifacts")
args = parser.parse_args()
app = args.app.resolve()
assert (app / "Contents/MacOS/Chauffeur.debug.dylib").is_file(), "Build the Debug app first"
root = Path.home() / "Library/Application Support/Chauffeur Debug"
for name in ("projects", "preset-sets"):
    directory = root / name
    assert not directory.exists() or not any(directory.iterdir()), "Use an empty default store for this check"
job = f"gui/{os.getuid()}/dev.chauffeur.debug.runtime"


def job_info():
    return subprocess.run(["launchctl", "print", job], capture_output=True, text=True)


assert job_info().returncode != 0 or args.replace_test_registration, "A service is already registered; use --replace-test-registration only for your empty test registration"
artifacts = args.artifacts.resolve()
artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
artifacts.chmod(0o700)
(artifacts / "summary.json").unlink(missing_ok=True)


def call(method):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(root / "runtime/runtime.sock"))
        data = json.dumps({"version": 1, "id": str(uuid.uuid4()), "method": method, "params": {}}).encode()
        connection.sendall(struct.pack("!I", len(data)) + data)

        def exact(size):
            result = bytearray()
            while len(result) < size:
                chunk = connection.recv(size - len(result))
                if not chunk:
                    raise OSError("Runtime disconnected")
                result.extend(chunk)
            return result

        size, = struct.unpack("!I", exact(4))
        assert size <= 8 * 1024 * 1024
        response = json.loads(exact(size))
        assert not response.get("error"), "Runtime request failed"
        return response["result"]


def wait_for(operation, predicate, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = operation()
            if predicate(value):
                return value
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    raise AssertionError("Service lifecycle check timed out")


def probe(name, restart=False, unregister=False):
    directory = artifacts / name
    directory.mkdir(mode=0o700, exist_ok=True)
    report = directory / "service-probe.json"
    report.unlink(missing_ok=True)
    environment = dict(os.environ, CHAUFFEUR_SERVICE_PROBE_DIR=str(directory))
    for key in ("CHAUFFEUR_SOCKET", "CHAUFFEUR_NATIVE_PROBE_DIR", "CHAUFFEUR_SERVICE_PROBE_RESTART", "CHAUFFEUR_SERVICE_PROBE_ACTION"):
        environment.pop(key, None)
    if restart:
        environment["CHAUFFEUR_SERVICE_PROBE_RESTART"] = "1"
    if unregister:
        environment["CHAUFFEUR_SERVICE_PROBE_ACTION"] = "unregister"
    with (directory / "app.log").open("w") as log:
        os.chmod(log.name, 0o600)
        # Deliberately retain normal macOS window restoration/launch behavior.
        process = subprocess.Popen([str(app / "Contents/MacOS/Chauffeur")], env=environment, stdout=log, stderr=log)
        try:
            assert process.wait(timeout=35) == 0, "Probe app failed"
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
    assert report.is_file(), "Debug app did not write a probe report"
    result = json.loads(report.read_text())
    assert result.get("error") is None and result.get("registrationError") is None, "Service registration failed; inspect the private report"
    if not unregister:
        assert result["online"] and result["status"] == "enabled", "Service did not become available"
        assert result["visibleWindows"] >= 1, "Normal launch did not show a window"
    return result


summary = {}
try:
    initial = probe("initial")
    first = wait_for(lambda: call("status"), lambda value: value.get("mcpEndpoint") is not None)
    assert first["runtimeID"] == initial["health"]["runtimeID"]
    match = re.search(r"^\s*pid = (\d+)$", job_info().stdout, re.MULTILINE)
    assert match is not None, "launchd has no running helper"
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    path = ctypes.create_string_buffer(4096)
    assert libproc.proc_pidpath(int(match[1]), path, len(path)) > 0
    assert Path(os.fsdecode(path.value)).resolve() == app / "Contents/MacOS/ChauffeurRuntime", "launchd selected a different app bundle"
    assert first["liveSessions"] == 0 and not call("snapshot")["sessions"], "Default runtime must have no sessions"
    summary["normalUIQuit"] = "same runtime remains available"
    notifications = wait_for(lambda: call("notificationStatus"), lambda value: value["authorization"] != "unavailable")
    assert not notifications["enabled"], "Use a default store with notifications disabled for this check"
    notification_app = app / "Contents/Library/ChauffeurNotifications.app"
    assert notification_app.is_dir(), "Notification helper is missing from the app bundle"
    subprocess.run(["/usr/bin/open", "-g", str(notification_app)], check=True, capture_output=True)
    notifications = wait_for(lambda: call("notificationStatus"), lambda value: value["helperConnected"] and value["authorization"] != "unknown")
    assert not notifications["enabled"]
    summary["notificationHelper"] = "Launch Services started the bundled helper with the UI closed; native authorization read without requesting permission"
    summary["notificationAuthorization"] = notifications["authorization"]
    subprocess.run(["launchctl", "kill", "SIGTERM", job], check=True, capture_output=True)
    recovered = wait_for(lambda: call("status"), lambda value: value["runtimeID"] != first["runtimeID"] and value.get("mcpEndpoint") is not None)
    assert recovered["mcpEndpoint"] == first["mcpEndpoint"]
    summary["launchdRecovery"] = "new runtime, same MCP endpoint, UI closed"
    relaunched = probe("relaunch")
    assert relaunched["health"]["runtimeID"] == recovered["runtimeID"]
    summary["UIRelaunch"] = "reconnected without restarting service"
    restarted = probe("restart", restart=True)
    assert restarted["health"]["runtimeID"] != recovered["runtimeID"]
    summary["appServiceRestart"] = "new runtime available through SMAppService"
finally:
    probe("cleanup", unregister=True)
    wait_for(job_info, lambda value: value.returncode != 0, timeout=10)
    summary["cleanup"] = "test service unregistered; empty data store retained"

summary["serviceLifetime"] = "pass"
summary["scope"] = "empty default store; no CLI sessions, Spaces, or OS UI automation"
output = artifacts / "summary.json"
output.write_text(json.dumps(summary, indent=2) + "\n")
output.chmod(0o600)
print(json.dumps(summary, indent=2))
