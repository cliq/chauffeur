#!/usr/bin/env python3
"""End-to-end onboarding fixture using isolated profiles and a fake local CLI."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


repository = Path(__file__).resolve().parents[1]
runtime_binary = (repository / ".build/debug/ChauffeurRuntime").resolve()
ctl_binary = (repository / ".build/debug/chauffeurctl").resolve()
assert runtime_binary.is_file() and os.access(runtime_binary, os.X_OK), "Run swift build first"
assert ctl_binary.is_file() and os.access(ctl_binary, os.X_OK), "Run swift build first"


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
        except (OSError, subprocess.SubprocessError, ValueError, AssertionError) as error:
            last_error = error
        time.sleep(0.05)
    raise AssertionError(f"Timed out waiting for runtime state: {last_error}")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def auth(phase="notChecked"):
    return {
        "phase": phase,
        "email": None,
        "organization": None,
        "method": None,
        "checkedAt": None,
        "message": None,
    }


def pair(kind, executable, choice, destination, source=None, categories=None):
    return {
        "id": uid(),
        "kind": kind,
        "executable": str(executable),
        "choice": choice,
        "sourcePath": str(source) if source else None,
        "destinationPath": str(destination),
        "categories": categories or ["preferences", "instructions", "reusable"],
        "projectPaths": [],
        "previewID": None,
        "operationID": None,
        "auth": auth(),
    }


with tempfile.TemporaryDirectory(prefix="chauffeur-onboarding-smoke-", dir="/tmp") as directory:
    fixture_root = Path(directory)
    data_root = fixture_root / "data"
    home = fixture_root / "home"
    bin_dir = fixture_root / "bin"
    checkout = fixture_root / "checkout"
    source = home / ".claude"
    shared_codex = home / ".codex-shared"
    claude_personal = home / ".claude-personal"
    claude_work = home / ".claude-work"
    for path in [data_root, home, bin_dir, checkout, source / "skills", shared_codex]:
        path.mkdir(parents=True, exist_ok=True)

    subprocess.run(["git", "-c", "init.defaultBranch=main", "init", "-q", str(checkout)], check=True)
    subprocess.run([
        "git", "-C", str(checkout), "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
        "commit", "-q", "--allow-empty", "-m", "Fixture",
    ], check=True)

    (source / "CLAUDE.md").write_text("Fixture instructions\n")
    (source / "skills" / "fixture.md").write_text("Fixture reusable skill\n")
    (source / "settings.json").write_text(json.dumps({
        "model": "sonnet",
        "hooks": {"Stop": [{"command": "must-not-copy"}]},
        "env": {"ANTHROPIC_API_KEY": "fixture-secret-must-not-copy"},
    }))
    source_hashes = {str(path.relative_to(source)): digest(path) for path in source.rglob("*") if path.is_file()}

    fake_cli = bin_dir / "fixture-agent"
    fake_cli.write_text(f"""#!{sys.executable}
import json, os, pathlib, sys, time
args = sys.argv[1:]
config = pathlib.Path(os.environ.get('CLAUDE_CONFIG_DIR') or os.environ.get('CODEX_HOME') or '.')
marker = config / '.fixture-authenticated'
if args == ['--version']:
    print('2.1.278 (Claude Code)' if 'CLAUDE_CONFIG_DIR' in os.environ else 'codex-cli 0.154.0')
elif args == ['--help']:
    print('--add-dir resume --mcp-config --settings --session-id')
elif args == ['login', '--help']:
    print('login status')
elif args == ['login', 'status']:
    if marker.exists(): print('Logged in using ChatGPT')
    else: print('Not logged in'); raise SystemExit(1)
elif args == ['login']:
    config.mkdir(parents=True, exist_ok=True); marker.touch()
elif args == ['auth', 'status', '--help']:
    print('--json')
elif args == ['auth', 'status', '--json']:
    print(json.dumps({{'loggedIn': marker.exists(), 'authMethod': 'oauth' if marker.exists() else 'none',
                      'email': 'fixture@example.test', 'organizationName': 'Fixture Org',
                      'configDirectory': str(config.resolve())}}))
    if not marker.exists(): raise SystemExit(1)
elif args == ['auth', 'login']:
    config.mkdir(parents=True, exist_ok=True); marker.touch()
elif os.environ.get('CHAUFFEUR_SESSION_ID'):
    payload = pathlib.Path.cwd() / ('.onboarding-launch-' + os.environ['CHAUFFEUR_SESSION_ID'] + '.json')
    payload.write_text(json.dumps({{
        'sessionID': os.environ['CHAUFFEUR_SESSION_ID'],
        'arguments': args,
        'codexHome': os.environ.get('CODEX_HOME'),
        'claudeConfigDir': os.environ.get('CLAUDE_CONFIG_DIR'),
        'inheritedCredential': any(key in os.environ for key in ['OPENAI_API_KEY', 'ANTHROPIC_API_KEY']),
    }}))
    time.sleep(30)
else:
    print('unsupported fixture invocation', args, file=sys.stderr); raise SystemExit(2)
""")
    fake_cli.chmod(0o700)
    (bin_dir / "codex").symlink_to(fake_cli)
    (bin_dir / "claude").symlink_to(fake_cli)

    socket_path = data_root / "runtime/runtime.sock"
    runtime_log_path = fixture_root / "runtime.log"
    runtime_log = runtime_log_path.open("w")
    runtime = None
    launched_session = None
    environment = dict(
        os.environ,
        HOME=str(home),
        PATH=str(bin_dir) + ":/usr/bin:/bin:/usr/sbin:/sbin",
        SHELL="/bin/sh",
        CHAUFFEUR_CODEX_EXECUTABLE=str(fake_cli),
        CHAUFFEUR_CLAUDE_EXECUTABLE=str(fake_cli),
        OPENAI_API_KEY="fixture-inherited-must-be-removed",
        ANTHROPIC_API_KEY="fixture-inherited-must-be-removed",
    )

    def start_runtime():
        return subprocess.Popen(
            [str(runtime_binary), "--data-dir", str(data_root)],
            cwd="/",
            env=environment,
            stdout=runtime_log,
            stderr=runtime_log,
        )

    def call(method, params=None):
        command = [str(ctl_binary), "request", method, json.dumps(params or {}), "--socket", str(socket_path)]
        try:
            output = subprocess.check_output(command, env=environment, text=True, stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as error:
            raise AssertionError(f"{method} failed: {error.stderr.strip()}") from error
        return json.loads(output)

    def stored_draft():
        stored = call("setupDraft")
        assert stored and stored["value"]["id"] == draft_id
        return stored

    def versioned(method, pair_id=None, extra=None):
        stored = stored_draft()
        params = {"draftID": draft_id, "expectedVersion": stored["version"]}
        if pair_id:
            params["pairID"] = pair_id
        params.update(extra or {})
        return call(method, params)

    def login(pair_id):
        before = call("verifySetupAuthentication", {"draftID": draft_id, "pairID": pair_id})
        assert before["phase"] == "signInRequired", before
        call("startSetupLogin", {"draftID": draft_id, "pairID": pair_id})
        return wait_for(
            stored_draft,
            lambda stored: next(
                agent for team in stored["value"]["teams"] for agent in team["agents"] if agent["id"] == pair_id
            )["auth"]["phase"] == "connected",
        )

    try:
        runtime = start_runtime()
        first_health = wait_for(lambda: call("status"), lambda value: value.get("status") == "running")
        inventory = call("setupInventory")
        assert inventory["executables"] == {"claude": str(fake_cli.resolve()), "codex": str(fake_cli.resolve())}
        assert inventory["missingAgents"] == []

        personal_id, work_id = uid(), uid()
        codex_personal = pair("codex", fake_cli, "existing", shared_codex)
        claude_personal_pair = pair("claude", fake_cli, "create", claude_personal, source, ["preferences", "instructions"])
        codex_work_pair = pair("codex", fake_cli, "existing", shared_codex)
        claude_work_pair = pair("claude", fake_cli, "create", claude_work, source, ["preferences", "instructions", "reusable"])
        draft_id = uid()
        draft = {
            "id": draft_id,
            "schemaVersion": 1,
            "step": "configurations",
            "accountCounts": {"codex": "single", "claude": "multiple"},
            "executables": {"codex": str(fake_cli), "claude": str(fake_cli)},
            "teams": [
                {"id": personal_id, "name": "Personal", "agents": [codex_personal, claude_personal_pair], "savedVersion": None},
                {"id": work_id, "name": "Work", "agents": [codex_work_pair, claude_work_pair], "savedVersion": None},
            ],
            "defaultTeamID": work_id,
            "dismissed": False,
            "completed": False,
        }
        saved = call("saveSetupDraft", {"record": draft})
        assert saved["value"]["id"] == draft_id

        for setup_pair, destination in [(claude_personal_pair, claude_personal), (claude_work_pair, claude_work)]:
            preview = versioned("previewSetupCopy", setup_pair["id"])
            entries = {entry["sourceRelativePath"]: entry for entry in preview["entries"]}
            assert entries["CLAUDE.md"]["sourceDigest"] == source_hashes["CLAUDE.md"]
            assert entries["settings.json"]["sourceDigest"] == source_hashes["settings.json"]
            if "reusable" in setup_pair["categories"]:
                assert entries["skills/fixture.md"]["sourceDigest"] == source_hashes["skills/fixture.md"]
            else:
                assert "skills/fixture.md" not in entries
            receipt = versioned("createSetupConfiguration", setup_pair["id"], {"previewID": preview["id"]})
            assert Path(receipt["destinationPath"]).resolve() == destination.resolve()
            copied_settings = json.loads((destination / "settings.json").read_text())
            assert copied_settings == {"model": "sonnet"}
            assert (destination / "CLAUDE.md").read_text() == "Fixture instructions\n"

        assert {str(path.relative_to(source)): digest(path) for path in source.rglob("*") if path.is_file()} == source_hashes
        assert not (claude_personal / "skills/fixture.md").exists()
        assert (claude_work / "skills/fixture.md").read_text() == "Fixture reusable skill\n"

        login(codex_personal["id"])
        shared_status = stored_draft()["value"]
        codex_statuses = [agent["auth"]["phase"] for team in shared_status["teams"] for agent in team["agents"] if agent["kind"] == "codex"]
        assert codex_statuses == ["connected", "connected"]
        login(claude_personal_pair["id"])
        login(claude_work_pair["id"])

        runtime.terminate()
        runtime.wait(timeout=5)
        runtime = start_runtime()
        wait_for(lambda: call("status"), lambda value: value.get("runtimeID") != first_health["runtimeID"])
        resumed = stored_draft()
        assert resumed["value"]["completed"] is False
        assert all(agent["auth"]["phase"] == "notChecked" for team in resumed["value"]["teams"] for agent in team["agents"])

        for pair_id in [codex_personal["id"], claude_personal_pair["id"], claude_work_pair["id"]]:
            status = call("verifySetupAuthentication", {"draftID": draft_id, "pairID": pair_id})
            assert status["phase"] == "connected", status
        assert all(agent["auth"]["phase"] == "connected" for team in stored_draft()["value"]["teams"] for agent in team["agents"])

        first_finish = versioned("finishSetup")
        assert set(first_finish) == {personal_id, work_id}
        completed = stored_draft()
        assert completed["value"]["completed"] is True
        second_finish = versioned("finishSetup")
        assert second_finish == first_finish
        snapshot = call("snapshot")["store"]
        setup_teams = [item for item in snapshot["presetSets"] if item["value"]["id"] in {personal_id, work_id}]
        assert {item["value"]["id"] for item in setup_teams} == {personal_id, work_id}
        assert len(setup_teams) == 2
        mappings = {item["value"]["id"]: item["value"]["configurationDirectories"] for item in setup_teams}
        assert mappings[personal_id] == {"codex": str(shared_codex.resolve()), "claude": str(claude_personal.resolve())}
        assert mappings[work_id] == {"codex": str(shared_codex.resolve()), "claude": str(claude_work.resolve())}

        project_id, folder_id, group_id = uid(), uid(), uid()
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        project = {
            "id": project_id,
            "name": "Onboarding Smoke Project",
            "presetSetID": work_id,
            "folders": [{
                "id": folder_id,
                "name": "Fixture checkout",
                "selectedPath": str(checkout),
                "canonicalPath": str(checkout.resolve()),
                "availability": "available",
                "registered": True,
            }],
            "groups": [{
                "id": group_id,
                "name": "Default",
                "isDefault": True,
                "archived": False,
                "createdAt": now,
                "updatedAt": now,
            }],
            "archived": False,
            "createdAt": now,
            "updatedAt": now,
            "lastOpenedAt": now,
        }
        call("saveProject", {"record": project})
        snapshot = call("snapshot")["store"]
        work_team = next(item["value"] for item in snapshot["presetSets"] if item["value"]["id"] == work_id)
        if work_team["agentSelection"] == "allBase":
            preset_id = next(item["value"]["id"] for item in snapshot["baseAgentPresets"] if item["value"]["kind"] == "claude")
        else:
            preset_id = next(item["value"]["id"] for item in snapshot["presets"] if item["value"]["setID"] == work_id and item["value"]["kind"] == "claude")
        launched_session = call("launch", {
            "projectID": project_id,
            "groupID": group_id,
            "presetID": preset_id,
            "folderID": folder_id,
            "additionalFolderIDs": [],
            "title": "Onboarding basic terminal",
            "allowSharedCheckout": True,
            "coordinationEnabled": False,
            "retryKey": uid(),
        })
        assert launched_session["launch"]["configurationPath"] == str(claude_work.resolve())
        assert launched_session["launch"]["preset"]["kind"] == "claude"
        assert launched_session["launch"]["preset"]["integration"] == "unavailable"
        launch_payload = wait_for(lambda: json.loads((checkout / (".onboarding-launch-" + launched_session["id"] + ".json")).read_text()))
        assert launch_payload["claudeConfigDir"] == str(claude_work.resolve())
        assert launch_payload["codexHome"] == str(shared_codex.resolve())
        assert launch_payload["inheritedCredential"] is False
        assert "--mcp-config" not in launch_payload["arguments"]

        print(json.dumps({
            "onboardingSmoke": "pass",
            "teams": [personal_id, work_id],
            "sharedCodex": str(shared_codex),
            "selectiveCopy": "source digests stable; credential fields excluded",
            "runtimeRestart": "draft resumed and authentication reverified",
            "finishRetry": "stable team IDs",
            "launch": "basic terminal used Work Claude configuration",
        }, indent=2))
    except Exception:
        runtime_log.flush()
        print(runtime_log_path.read_text()[-6000:], file=sys.stderr)
        raise
    finally:
        if launched_session and runtime and runtime.poll() is None:
            try:
                call("stop", {"sessionID": launched_session["id"], "force": True})
            except Exception:
                pass
        if runtime and runtime.poll() is None:
            runtime.terminate()
            try:
                runtime.wait(timeout=5)
            except subprocess.TimeoutExpired:
                runtime.kill()
                runtime.wait(timeout=5)
        tmux = shutil.which("tmux")
        owned_socket = data_root / "runtime/tmux.sock"
        if tmux and owned_socket.exists():
            subprocess.run([tmux, "-S", str(owned_socket), "kill-server"], capture_output=True)
        runtime_log.close()
