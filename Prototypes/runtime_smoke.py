#!/usr/bin/env python3
"""V1/V2/V3/V4 runtime fixture integration; no real CLI accounts or provider calls."""
from datetime import datetime, timezone
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import time
import tomllib
import uuid

repository = Path(__file__).resolve().parents[1]
binary = Path(os.environ.get("CHAUFFEUR_RUNTIME_BINARY", repository / ".build/debug/ChauffeurRuntime")).resolve()
fixture = repository / "Prototypes/fake_cli.py"
assert binary.exists(), "Run swift build first"

def uid():
    return str(uuid.uuid4()).upper()

def wait_for(probe, predicate=lambda value: bool(value), timeout=20):
    deadline = time.monotonic() + timeout
    last_error = None
    while time.monotonic() < deadline:
        try:
            value = probe()
            if predicate(value):
                return value
        except (OSError, ValueError, AssertionError) as error:
            last_error = error
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {last_error}")

def send_frame(connection, value):
    data = json.dumps(value).encode()
    connection.sendall(struct.pack("!I", len(data)) + data)

def receive_frame(connection):
    def exact(count):
        chunks = bytearray()
        while len(chunks) < count:
            part = connection.recv(count - len(chunks))
            assert part, "Connection closed"
            chunks.extend(part)
        return chunks
    count, = struct.unpack("!I", exact(4))
    assert count <= 8 * 1024 * 1024
    return json.loads(exact(count))

def request(method, params=None):
    return {"version": 1, "id": uid(), "method": method, "params": params or {}}

with tempfile.TemporaryDirectory(prefix="chauffeur-smoke-", dir="/tmp") as directory:
    root = Path(directory)
    config = root / "existing profile α"
    checkout = root / "repo with spaces"
    config.mkdir(); checkout.mkdir()
    subprocess.run(["git", "-c", "init.defaultBranch=main", "init", "-q", str(checkout)], check=True)
    subprocess.run(["git", "-C", str(checkout), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "Fixture"], check=True)
    socket_path = str(root / "runtime/runtime.sock")
    log = open(root / "runtime.log", "w")
    runtime = None
    attachments = []
    # Exercise launchd's minimal PATH and an unavailable login shell too.
    environment = dict(os.environ, OPENAI_API_KEY="fixture-must-be-removed", PATH="/usr/bin:/bin:/usr/sbin:/sbin", SHELL="/nonexistent-fixture-shell")
    def start_runtime():
        # SMAppService can use the bundle-relative BundleProgram as argv[0].
        # The runtime must locate its sibling helper using its loaded executable.
        return subprocess.Popen(["Contents/MacOS/ChauffeurRuntime", "--data-dir", str(root)], executable=str(binary), cwd="/", stdout=log, stderr=log, env=environment)
    def call(method, params=None):
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30)
            connection.connect(socket_path)
            send_frame(connection, request(method, params))
            response = receive_frame(connection)
            assert not response.get("error"), response.get("error")
            return response.get("result")
    def mcp(token, method, params=None, origin=None):
        port = json.loads((root / "runtime/mcp-port.json").read_text())
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        if origin:
            headers["Origin"] = origin
        connection.request("POST", "/mcp", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}), headers)
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, json.loads(data) if data else None
    def tool(token, name, args=None):
        status, response = mcp(token, "tools/call", {"name": name, "arguments": args or {}})
        assert status == 200, status
        result = response["result"]
        return result.get("isError", False), json.loads(result["content"][0]["text"]) if not result.get("isError") else result["content"][0]["text"]
    def attach(session_id):
        connection = socket.socket(socket.AF_UNIX)
        connection.settimeout(5); connection.connect(socket_path)
        send_frame(connection, request("attach", {"sessionID": session_id, "owner": uid(), "cols": 100, "rows": 30}))
        assert receive_frame(connection)["result"]["stream"]
        import base64
        output = bytearray()
        while b"Chauffeur fixture" not in output:
            frame = receive_frame(connection)
            assert frame["kind"] != "error", frame
            output.extend(base64.b64decode(frame.get("bytes", "")))
        attachments.append(connection)
        return connection
    try:
        runtime = start_runtime()
        health = wait_for(lambda: call("status"), lambda value: value.get("mcpEndpoint"))
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        set_id, preset_id, project_id, folder_id, group_id, outside_id = [uid() for _ in range(6)]
        call("savePresetSet", {"record": {"id": set_id, "name": "Fixture set", "revision": 1, "archived": False}})
        call("savePreset", {"record": {"id": preset_id, "setID": set_id, "name": "Fake Codex", "kind": "codex", "executable": str(fixture), "configurationDirectory": str(config), "arguments": [], "integration": "unverified", "archived": False}})
        call("saveProject", {"record": {"id": project_id, "name": "Runtime fixture", "presetSetID": set_id, "folders": [{"id": folder_id, "name": "Fixture checkout", "selectedPath": str(checkout), "canonicalPath": str(checkout.resolve()), "availability": "available", "registered": True}], "groups": [{"id": group_id, "name": "Default", "isDefault": True, "archived": False, "createdAt": now, "updatedAt": now}, {"id": outside_id, "name": "Other", "isDefault": False, "archived": False, "createdAt": now, "updatedAt": now}], "archived": False, "createdAt": now, "updatedAt": now, "lastOpenedAt": now}})
        worktree_args = {"projectID": project_id, "folderID": folder_id, "branch": "fixture/managed", "baseRef": "HEAD"}
        preview = call("previewWorktree", worktree_args)["path"]
        managed = call("createWorktree", worktree_args)["value"]
        assert Path(managed["path"]).resolve() == Path(preview).resolve()
        assert any(item["path"] == managed["path"] for item in call("worktreeInventory", {"path": str(checkout)}))
        call("removeWorktree", {"worktreeID": managed["id"]})
        assert not Path(managed["path"]).exists()
        external_path = root / "external checkout"
        subprocess.run(["git", "-C", str(checkout), "-c", "core.hooksPath=/dev/null", "worktree", "add", "-q", "-b", "fixture/external", str(external_path)], check=True)
        external_args = {"projectID": project_id, "folderID": folder_id, "path": str(external_path)}
        external = call("registerWorktree", external_args)["value"]
        assert external["managed"] is False
        call("removeWorktree", {"worktreeID": external["id"]})
        assert external_path.is_dir(), "Unregistering an external worktree must preserve its files"
        assert call("registerWorktree", external_args)["value"]["id"] == external["id"]
        sessions, credentials = [], []
        for index, group in enumerate([group_id, group_id, outside_id]):
            launch = {"projectID": project_id, "groupID": group, "presetID": preset_id, "folderID": folder_id, "additionalFolderIDs": [], "title": f"Fixture {index}", "allowSharedCheckout": True, "coordinationEnabled": True, "retryKey": uid()}
            session = call("launch", launch)
            assert call("launch", launch)["id"] == session["id"]
            payload = wait_for(lambda: json.loads((checkout / (".chauffeur-fixture-" + session["id"] + ".json")).read_text()))
            assert payload["configurationPath"] == str(config.resolve()) and not payload["inheritedAPIKey"]
            # Check generated arguments with a TOML parser, as the real Codex CLI
            # does. JSON's optional escaped slash breaks URL and notify values.
            argv = payload["arguments"]
            overrides = tomllib.loads("\n".join(argv[i + 1] for i, arg in enumerate(argv) if arg == "-c"))
            assert overrides["mcp_servers"]["chauffeur"]["url"] == health["mcpEndpoint"]
            assert overrides["mcp_servers"]["chauffeur"]["bearer_token_env_var"] == "CHAUFFEUR_SESSION_TOKEN"
            assert overrides["notify"] == [str(binary.parent / "chauffeurctl"), "event", "--session", session["id"], "turn-finished"]
            sessions.append(session); credentials.append(payload)
        assert len({value["token"] for value in credentials}) == 3
        token_a, token_b, token_other = [item["token"] for item in credentials]
        assert mcp(None, "initialize")[0] == 401
        assert mcp("invalid", "initialize")[0] == 401
        assert mcp(token_a, "initialize", origin="https://evil.invalid")[0] == 403
        assert len(mcp(token_a, "tools/list")[1]["result"]["tools"]) == 7
        error, discovered = tool(token_a, "chauffeur_discover")
        assert not error and len(discovered["peers"]) == 2
        message_args = {"recipientID": sessions[1]["id"], "body": "Durable fixture message", "retryKey": "one"}
        error, message = tool(token_a, "chauffeur_send_message", message_args)
        assert not error and message["state"] == "queued"
        assert tool(token_a, "chauffeur_send_message", message_args)[1]["id"] == message["id"]
        assert tool(token_other, "chauffeur_reply", {"messageID": message["id"], "body": "cross", "retryKey": "probe"})[0]
        assert tool(token_other, "chauffeur_send_message", message_args)[0]
        connection = attach(sessions[0]["id"])
        import base64
        send_frame(connection, request("input", {"bytes": base64.b64encode(b"unsent fixture input").decode()}))
        time.sleep(0.15)
        connection.close(); attachments.remove(connection)
        time.sleep(0.2)
        reattached = attach(sessions[0]["id"])
        send_frame(reattached, request("resize", {"cols": 110, "rows": 35}))
        reattached.close(); attachments.remove(reattached)
        # Multiple views can request the first archive while periodic capture is
        # also running. Every caller must receive the completed capture.
        (root / "runtime/snapshots" / sessions[0]["id"] / "latest.json").unlink(missing_ok=True)
        with ThreadPoolExecutor(max_workers=8) as pool:
            captures = list(pool.map(lambda _: call("terminalSnapshot", {"sessionID": sessions[0]["id"]}), range(8)))
        assert all("fixture-history-249" in value["history"] for value in captures)
        saved_history = captures[0]
        assert "fixture-history-000" in saved_history["history"]
        assert "fixture-history-249" in saved_history["history"]
        assert "Chauffeur fixture" in saved_history["screen"]
        assert "unsent fixture input" in saved_history["screen"]
        settings = call("snapshot")["settings"]
        settings["scrollbackLines"] = 100
        settings["snapshotBudgetBytes"] = 1048576
        call("saveSettings", settings)
        trimmed = call("terminalSnapshot", {"sessionID": sessions[0]["id"]})
        assert "fixture-history-000" not in trimmed["history"]
        assert "fixture-history-249" in trimmed["history"]
        assert len(trimmed["history"].splitlines()) <= 100 and trimmed["truncated"]
        runtime.kill(); runtime.wait(timeout=5)
        runtime = start_runtime()
        new_health = wait_for(lambda: call("status"), lambda value: value.get("runtimeID") != health["runtimeID"] and value.get("mcpEndpoint"))
        restored = call("snapshot")
        assert any(issue["code"] == "login_environment_unavailable" for issue in restored["errors"])
        assert new_health["mcpEndpoint"] == health["mcpEndpoint"]
        assert {item["processID"] for item in restored["sessions"]} == {item["pid"] for item in credentials}
        assert all(item["state"] == "activityUnknown" for item in restored["sessions"])
        assert call("terminalSnapshot", {"sessionID": sessions[0]["id"]})["history"] == trimmed["history"]
        error, inbox = tool(token_b, "chauffeur_inbox")
        assert not error and inbox[0]["id"] == message["id"] and inbox[0]["state"] == "received"
        assert not tool(token_b, "chauffeur_inbox", {"acknowledge": [message["id"]]})[0]
        call("stop", {"sessionID": sessions[0]["id"], "force": True})
        assert "unsent fixture input" in call("terminalSnapshot", {"sessionID": sessions[0]["id"]})["screen"]
        assert mcp(token_a, "ping")[0] == 401
        assert mcp(token_b, "ping")[0] == 200
        # Lose the terminal service entirely: no implicit replay, archive still readable.
        call("terminalSnapshot", {"sessionID": sessions[1]["id"]})
        subprocess.run([shutil.which("tmux"), "-S", str(root / "runtime/tmux.sock"), "kill-server"], check=True)
        call("reconcile")
        interrupted = call("snapshot")
        assert all(item["state"] == "interrupted" for item in interrupted["sessions"])
        runtime.kill(); runtime.wait(timeout=5)
        runtime = start_runtime()
        wait_for(lambda: call("status"), lambda value: value.get("runtimeID") != new_health["runtimeID"] and value.get("mcpEndpoint"))
        assert "fixture-history-249" in call("terminalSnapshot", {"sessionID": sessions[1]["id"]})["history"]
        retention_sessions = []
        for limit in [100, 200]:
            settings["scrollbackLines"] = limit
            call("saveSettings", settings)
            launch["retryKey"] = uid()
            extra = call("launch", launch)
            retention_sessions.append(extra)
            pane_limit = subprocess.check_output([shutil.which("tmux"), "-S", str(root / "runtime/tmux.sock"), "display-message", "-p", "-t", extra["id"], "#{history_limit}"], text=True).strip()
            assert int(pane_limit) == limit, pane_limit
        # Changing the default does not resize existing live tmux buffers.
        pane_limit = subprocess.check_output([shutil.which("tmux"), "-S", str(root / "runtime/tmux.sock"), "display-message", "-p", "-t", retention_sessions[0]["id"], "#{history_limit}"], text=True).strip()
        assert int(pane_limit) == 100
        for extra in retention_sessions:
            call("interrupt", {"sessionID": extra["id"]})
            wait_for(lambda: call("snapshot"), lambda value: next(item for item in value["sessions"] if item["id"] == extra["id"])["state"] == "exited")
            def pane_names():
                return subprocess.run([shutil.which("tmux"), "-S", str(root / "runtime/tmux.sock"), "list-sessions", "-F", "#{session_name}"], capture_output=True, text=True).stdout
            wait_for(pane_names, lambda value: extra["id"] not in value)
            archive = call("terminalSnapshot", {"sessionID": extra["id"]})
            assert "fixture-history-249" in archive["history"] + archive["screen"]
        print(json.dumps({"runtimeFixture": "pass", "sessions": 3, "profileEnvironment": "isolated", "terminalReattachment": "pass", "runtimeRestart": "same tmux-owned processes and MCP port", "terminalHistory": "bounded normal history and active screen survive terminal and runtime loss", "mailboxPersistence": "pass", "groupProbes": "rejected", "retries": "same record IDs", "revocation": "pass", "realCLIValidation": "pending"}, indent=2))
    except Exception:
        log.flush()
        print((root / "runtime.log").read_text()[-4000:])
        raise
    finally:
        for connection in attachments:
            connection.close()
        if runtime and runtime.poll() is None:
            runtime.terminate()
            try:
                runtime.wait(timeout=5)
            except subprocess.TimeoutExpired:
                runtime.kill(); runtime.wait(timeout=5)
        subprocess.run([shutil.which("tmux"), "-S", str(root / "runtime/tmux.sock"), "kill-server"], capture_output=True)
        log.close()
