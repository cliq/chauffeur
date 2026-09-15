#!/usr/bin/env python3
"""Skill IPC/install/native discovery fixture. No inference prompts.

Requires the baseline Codex and Claude executables on PATH. Every CLI starts
with an empty fixture HOME and profile; Claude's dummy key points at localhost.
CHAUFFEUR_RUNTIME_BINARY can select a relocated app's embedded helper.
"""
import json
import os
from pathlib import Path
import selectors
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import uuid

repository = Path(__file__).resolve().parents[1]
binary = Path(os.environ.get("CHAUFFEUR_RUNTIME_BINARY", repository / ".build/debug/ChauffeurRuntime")).resolve()


def exchange(process, value, predicate):
    process.stdin.write((json.dumps(value) + "\n").encode()); process.stdin.flush()
    selector = selectors.DefaultSelector(); selector.register(process.stdout, selectors.EVENT_READ)
    buffer = bytearray(); deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            if not selector.select(0.1):
                continue
            data = os.read(process.stdout.fileno(), 65_536)
            assert data, "CLI closed before its metadata response"
            buffer.extend(data)
            while b"\n" in buffer:
                line, _, buffer = buffer.partition(b"\n")
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if predicate(item):
                    return item
        raise AssertionError("CLI metadata request timed out")
    finally:
        selector.close()


def discover(kind, profile, home, cwd):
    prefixes = ("CODEX_", "CLAUDE_", "CLAUDECODE", "OPENAI_", "ANTHROPIC_", "CHAUFFEUR_", "AWS_", "GOOGLE_", "VERTEX_", "BEDROCK_")
    environment = {key: value for key, value in os.environ.items() if not key.startswith(prefixes)}
    environment.update(HOME=str(home), CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", ANTHROPIC_API_KEY="fixture-not-a-credential", ANTHROPIC_BASE_URL="http://127.0.0.1:9")
    environment["CODEX_HOME" if kind == "codex" else "CLAUDE_CONFIG_DIR"] = str(profile)
    if kind == "codex":
        command = [shutil.which("codex"), "app-server", "--listen", "stdio://", "-c", "analytics.enabled=false", "-c", "feedback.enabled=false"]
    else:
        command = [shutil.which("claude"), "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--setting-sources", "user", "--tools", ""]
    with (profile / "discovery.private.log").open("wb") as log:
        process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        try:
            if kind == "codex":
                exchange(process, {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "chauffeur_skill_fixture", "version": "1.0.0"}, "capabilities": {"experimentalApi": True}}}, lambda item: item.get("id") == 1)
                process.stdin.write(b'{"method":"initialized"}\n'); process.stdin.flush()
                response = exchange(process, {"id": 2, "method": "skills/list", "params": {"cwds": [str(cwd)], "forceReload": True}}, lambda item: item.get("id") == 2)
                assert "error" not in response, "Codex skills/list failed"
                matches = [skill for listing in response["result"]["data"] for skill in listing["skills"] if skill["name"] == "chauffeur"]
                if matches:
                    assert len(matches) == 1 and matches[0]["enabled"]
                    assert Path(matches[0]["path"]).resolve() == (profile / "skills/chauffeur/SKILL.md").resolve()
                return bool(matches)
            response = exchange(process, {"type": "control_request", "request_id": "fixture-init", "request": {"subtype": "initialize"}}, lambda item: item.get("type") == "control_response" and item.get("response", {}).get("request_id") == "fixture-init")["response"]
            assert response["subtype"] == "success", "Claude metadata initialization failed"
            matches = [entry for entry in response["response"].get("commands", []) if entry.get("name") == "chauffeur"]
            if matches:
                assert len(matches) == 1 and matches[0]["description"].startswith("Coordinate with peer sessions through Chauffeur")
            return bool(matches)
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait(timeout=5)
            process.stdin.close(); process.stdout.close()


def run():
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="ch-skill-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        home = root / "home"; home.mkdir()
        cwd = root / "cwd"; cwd.mkdir()
        data_root = root / "data"
        socket_path = data_root / "runtime/runtime.sock"
        def call(method, params=None, error=False):
            request = {"version": 1, "id": str(uuid.uuid4()).upper(), "method": method, "params": params or {}}
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(20); connection.connect(str(socket_path))
                body = json.dumps(request).encode()
                connection.sendall(struct.pack("!I", len(body)) + body)
                def exact(count):
                    result = bytearray()
                    while len(result) < count:
                        part = connection.recv(count - len(result)); assert part
                        result.extend(part)
                    return result
                size, = struct.unpack("!I", exact(4)); assert size < 8 * 1024 * 1024
                response = json.loads(exact(size))
                assert bool(response.get("error")) == error, response.get("error")
                return response.get("error") if error else response.get("result")
        with (root / "runtime.private.log").open("wb") as log:
            runtime = subprocess.Popen([str(binary), "--data-dir", str(data_root)], cwd="/", stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 20
                while not socket_path.exists() and time.monotonic() < deadline:
                    assert runtime.poll() is None, "Runtime exited before opening its socket"
                    time.sleep(0.05)
                assert call("skillDocument") == (repository / "Sources/ChauffeurCore/Resources/Skills/chauffeur/SKILL.md").read_text()
                set_id = str(uuid.uuid4()).upper()
                call("savePresetSet", {"record": {"id": set_id, "name": "Skill fixture", "revision": 1, "archived": False}})
                for kind in ["codex", "claude"]:
                    profile = root / (kind + "-a"); profile.mkdir()
                    other = root / (kind + "-b"); other.mkdir()
                    (profile / "unrelated.txt").write_text("preserve fixture")
                    preset_id = str(uuid.uuid4()).upper()
                    record = {"id": preset_id, "setID": set_id, "name": kind + " fixture", "kind": kind, "executable": kind, "configurationDirectory": str(profile), "arguments": [], "integration": "unverified", "archived": False}
                    call("savePreset", {"record": record})
                    status = call("skillStatus", {"presetID": preset_id})
                    assert status["state"] == "notInstalled"
                    installed = call("installSkill", {"presetID": preset_id, "revision": status["revision"]})
                    assert installed["state"] == "installed"
                    assert discover(kind, profile, home, cwd), kind + " failed to discover installed guidance"
                    assert not discover(kind, other, home, cwd), kind + " leaked guidance into another profile"
                    assert call("removeSkill", {"presetID": preset_id, "revision": status["revision"]}, error=True)["code"] == "edit_conflict"
                    removed = call("removeSkill", {"presetID": preset_id, "revision": installed["revision"]})
                    assert removed["state"] == "notInstalled"
                    assert not discover(kind, profile, home, cwd), kind + " still discovers removed guidance"
                    assert (profile / "unrelated.txt").read_text() == "preserve fixture"
                    # Codex can add its own .system skills during discovery.
                    assert not (profile / "skills/chauffeur").exists()
                    assert not any(path.name.startswith(".chauffeur-") for path in (profile / "skills").iterdir())
                    print(kind + ": IPC install, native discovery, second-profile isolation, stale review rejection, removal passed", flush=True)
            finally:
                runtime.terminate()
                try:
                    runtime.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    runtime.kill(); runtime.wait(timeout=5)
    print("Skill installation fixture passed; no inference requested", flush=True)


if __name__ == "__main__":
    run()
