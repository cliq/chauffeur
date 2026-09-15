#!/usr/bin/env python3
"""Real Git/socket checks for background inventory and removal/launch races."""
from concurrent.futures import ThreadPoolExecutor
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
binary = Path(os.environ.get("CHAUFFEUR_RUNTIME_BINARY", repository / ".build/debug/ChauffeurRuntime")).resolve()
race_only = os.environ.get("CHAUFFEUR_WORKTREE_RACE_ONLY") == "1"

def uid():
    return str(uuid.uuid4()).upper()

def wait_for(probe, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value:
                return value
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.05)
    raise AssertionError("Fixture observation timed out")

with tempfile.TemporaryDirectory(prefix="chauffeur-worktree-", dir="/tmp") as directory:
    root = Path(directory)
    checkout, config = root / "repo", root / "profile"
    checkout.mkdir(); config.mkdir()
    def git(*args):
        return subprocess.check_output(["/usr/bin/git", "-C", str(checkout), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args], stderr=subprocess.PIPE, text=True).strip()
    git("init", "-b", "main")
    (checkout / "tracked.txt").write_text("fixture\n")
    git("add", "tracked.txt")
    git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Initial")
    log = (root / "runtime.log").open("w")
    runtime = subprocess.Popen([str(binary), "--data-dir", str(root)], stdout=log, stderr=log, env=dict(os.environ, SHELL="/nonexistent-fixture-shell"))
    def call(method, params=None, expect_error=False):
        def exact(connection, count):
            result = bytearray()
            while len(result) < count:
                chunk = connection.recv(count - len(result))
                assert chunk, "Connection closed"
                result.extend(chunk)
            return result
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(35); connection.connect(str(root / "runtime/runtime.sock"))
            data = json.dumps({"version": 1, "id": uid(), "method": method, "params": params or {}}).encode()
            connection.sendall(struct.pack("!I", len(data)) + data)
            length, = struct.unpack("!I", exact(connection, 4))
            assert length <= 8 * 1024 * 1024
            response = json.loads(exact(connection, length))
            if expect_error:
                return response.get("error", {}).get("code")
            assert not response.get("error"), response.get("error")
            return response.get("result")
    release = root / "release-status"
    try:
        wait_for(lambda: call("status").get("mcpEndpoint"))
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        set_id, preset_id, project_id, folder_id, group_id = [uid() for _ in range(5)]
        call("savePresetSet", {"record": {"id": set_id, "name": "Fixture", "revision": 1, "archived": False}})
        call("savePreset", {"record": {"id": preset_id, "setID": set_id, "name": "Fixture", "kind": "codex", "executable": str(repository / "Prototypes/fake_cli.py"), "configurationDirectory": str(config), "arguments": [], "integration": "unverified", "archived": False}})
        def folder(path, identifier):
            return {"id": identifier, "name": "Fixture", "selectedPath": str(path), "canonicalPath": str(path.resolve()), "availability": "available", "registered": True}
        project = {"id": project_id, "name": "Fixture", "presetSetID": set_id, "folders": [folder(checkout, folder_id)], "groups": [{"id": group_id, "name": "Default", "isDefault": True, "archived": False, "createdAt": now, "updatedAt": now}], "archived": False, "createdAt": now, "updatedAt": now, "lastOpenedAt": now}
        saved_project = call("saveProject", {"record": project})
        def create(branch):
            return call("createWorktree", {"projectID": project_id, "folderID": folder_id, "branch": branch, "baseRef": "main"})["value"]
        def record(identifier):
            return next(item["value"] for item in call("snapshot")["store"]["worktrees"] if item["value"]["id"] == identifier)
        tree = create("fixture/removal-race")
        alias = root / "alias"; alias.symlink_to(tree["path"])
        extra_id = uid(); project["folders"].append(folder(alias, extra_id))
        call("saveProject", {"record": project, "version": saved_project["version"]})
        # Git invokes this hook inside status, after the runtime's original
        # live-session check. It keeps that exact race window open deterministically.
        entered = root / "entered-status"
        hook = root / "fsmonitor-hook.py"
        hook.write_text("#!/usr/bin/env python3\nimport pathlib, sys, time\n"
                        f"pathlib.Path({str(entered)!r}).touch()\n"
                        f"deadline = time.monotonic() + 20\nwhile not pathlib.Path({str(release)!r}).exists() and time.monotonic() < deadline: time.sleep(0.02)\n"
                        "sys.stdout.buffer.write(b'fixture-token\\0/\\0')\n")
        hook.chmod(0o700)
        git("config", "core.fsmonitor", str(hook)); git("config", "core.fsmonitorHookVersion", "2")
        with ThreadPoolExecutor(max_workers=1) as pool:
            removal = pool.submit(call, "removeWorktree", {"worktreeID": tree["id"]})
            try:
                wait_for(entered.exists)
                launch = {"projectID": project_id, "groupID": group_id, "presetID": preset_id, "folderID": folder_id, "additionalFolderIDs": [], "worktreeID": tree["id"], "title": "Fixture", "allowSharedCheckout": True, "coordinationEnabled": False, "retryKey": uid()}
                code = call("launch", launch, expect_error=True)
                assert code == "worktree_busy", f"Launch entered a checkout during removal: {code!r}"
                launch.pop("worktreeID"); launch["additionalFolderIDs"] = [extra_id]; launch["retryKey"] = uid()
                assert call("launch", launch, expect_error=True) == "worktree_busy", "Additional directory bypassed removal claim"
            finally:
                release.touch()
            assert removal.result(timeout=30)["value"]["registered"] is False
        git("config", "--unset", "core.fsmonitor"); git("config", "--unset", "core.fsmonitorHookVersion")
        assert not Path(tree["path"]).exists()
        assert git("show-ref", "--verify", "refs/heads/fixture/removal-race")
        if not race_only:
            # No explicit refresh calls: the runtime must observe external Git
            # changes while the app is closed.
            tree = create("fixture/move")
            original_id, original_base = tree["id"], tree["baseCommit"]
            moved = Path(tree["path"]).with_name("moved-checkout")
            git("worktree", "move", tree["path"], str(moved))
            wait_for(lambda: record(original_id)["path"] == str(moved.resolve()))
            assert record(original_id)["managed"] and record(original_id)["baseCommit"] == original_base
            subprocess.run(["/usr/bin/git", "-C", str(moved), "branch", "-m", "fixture/renamed"], check=True)
            wait_for(lambda: record(original_id)["branch"] == "fixture/renamed")
            assert record(original_id)["baseCommit"] == original_base
            # Replacement at the same path is a different worktree.
            git("worktree", "remove", str(moved))
            git("worktree", "add", "-b", "fixture/replacement", str(moved), "main")
            wait_for(lambda: record(original_id)["availability"] == "missing")
            assert call("removeWorktree", {"worktreeID": original_id}, expect_error=True) == "worktree_unavailable"
            assert moved.exists()
            replacement = call("registerWorktree", {"projectID": project_id, "folderID": folder_id, "path": str(moved)})["value"]
            assert replacement["id"] != original_id and not replacement["managed"]
            external = root / "external-new"
            git("worktree", "add", "-b", "fixture/external", str(external), "main")
            wait_for(lambda: any(entry["path"] == str(external.resolve()) for observation in call("snapshot")["repositoryInventories"] for entry in observation["entries"]))
            registered = call("registerWorktree", {"projectID": project_id, "folderID": folder_id, "path": str(external)})["value"]
            outside = root / "moved-outside"
            git("worktree", "move", str(external), str(outside))
            wait_for(lambda: record(registered["id"])["path"] == str(outside.resolve()))
            call("removeWorktree", {"worktreeID": registered["id"]})
            assert outside.exists(), "Unregister deleted an external checkout"
            # A worktree can also be used through an ordinary folder registration.
            # Moving it must not hide that live session from removal protection.
            active = create("fixture/active-folder")
            active_folder_id = uid()
            latest_project = next(item for item in call("snapshot")["store"]["projects"] if item["value"]["id"] == project_id)
            latest_project["value"]["folders"].append(folder(Path(active["path"]), active_folder_id))
            call("saveProject", {"record": latest_project["value"], "version": latest_project["version"]})
            launch.update(folderID=active_folder_id, additionalFolderIDs=[], retryKey=uid())
            live = call("launch", launch)
            assert active["gitIdentity"] in live["launch"]["gitWorktreeIdentities"]
            moved_active = Path(active["path"]).with_name("moved-active")
            git("worktree", "move", active["path"], str(moved_active))
            wait_for(lambda: record(active["id"])["path"] == str(moved_active.resolve()))
            assert call("removeWorktree", {"worktreeID": active["id"]}, expect_error=True) == "active_worktree"
            retained = next(item for item in call("snapshot")["sessions"] if item["id"] == live["id"])
            assert retained["launch"]["workingDirectory"] == active["path"], "Reconciliation rewrote launch history"
            launch.update(folderID=folder_id, worktreeID=active["id"], allowSharedCheckout=False, retryKey=uid())
            assert call("launch", launch, expect_error=True) == "shared_checkout", "Move hid shared-checkout warning"
            call("stop", {"sessionID": live["id"], "force": True})
        print(json.dumps({"worktreeFixture": "pass", "removalRace": "primary and additional launches rejected while Git status waits", "inventory": "race-only" if race_only else "external add, move, branch rename, replacement, unregister", "branches": "preserved"}, indent=2))
    finally:
        release.touch()
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
