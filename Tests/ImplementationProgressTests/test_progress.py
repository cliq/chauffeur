import json
import os
from pathlib import Path
import subprocess
import sys
import socket
import struct
import threading
import tempfile
import unittest

sys.dont_write_bytecode = True

SCRIPT = Path(__file__).resolve().parents[2] / "Sources/ChauffeurCore/Resources/Skills/implementation-progress/scripts/progress.py"
ENV = {k: v for k, v in os.environ.items() if not k.startswith("CHAUFFEUR_") and k != "PROGRESS_DIR"}


class ProgressTests(unittest.TestCase):
    def test_updates_publish_versioned_json_and_matching_javascript(self):
        with tempfile.TemporaryDirectory() as directory:
            def run(*args):
                subprocess.run([sys.executable, str(SCRIPT), *args, "--dir", directory],
                               env=ENV, check=True, capture_output=True, text=True)

            def snapshot():
                root = Path(directory)
                data = json.loads((root / "progress.json").read_text())
                javascript = (root / "progress.js").read_text()
                self.assertEqual(json.loads(javascript[len("window.IMPLEMENTATION_PROGRESS = "):].strip()[:-1]), data)
                self.assertEqual(data.get("schemaVersion"), 1)
                return data

            run("init", "--title", "Fixture", "--phase", "Build", "--phase", "Check")
            original_html = (Path(directory) / "index.html").read_bytes()
            self.assertEqual(snapshot()["percentComplete"], 25)
            run("step", "1", "First", "done")
            run("step", "1", "Second", "blocked")
            run("phase", "1", "done")
            self.assertEqual(snapshot()["phases"][0]["steps"][1]["state"], "blocked")
            self.assertEqual(snapshot()["percentComplete"], 50)
            run("phase", "2", "active")
            self.assertEqual(snapshot()["percentComplete"], 75)
            run("phase", "2", "done")
            run("now", "Finished ✓")
            self.assertEqual(snapshot()["percentComplete"], 100)
            self.assertEqual(snapshot()["now"], "Finished ✓")
            self.assertEqual((Path(directory) / "index.html").read_bytes(), original_html)

    def test_legacy_json_is_upgraded_on_next_update(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "progress.json"
            path.write_text(json.dumps({"title": "Legacy", "phases": [], "now": "Before"}))
            subprocess.run([sys.executable, str(SCRIPT), "now", "--dir", directory, "After"], env=ENV, check=True)
            data = json.loads(path.read_text())
            self.assertEqual(data.get("schemaVersion"), 1)
            self.assertEqual(data["percentComplete"], 0)

    def test_percentage_rounds_halves_up_like_the_html(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([sys.executable, str(SCRIPT), "init", "--dir", directory,
                            "--title", "Rounding", "--phase", "One", "--phase", "Two",
                            "--phase", "Three", "--phase", "Four"], env=ENV, check=True, capture_output=True)
            self.assertEqual(json.loads((Path(directory) / "progress.json").read_text())["percentComplete"], 13)


class ChauffeurRegistrationTests(unittest.TestCase):
    def run_panel(self, directory, *args, environment=None):
        return subprocess.run([sys.executable, str(SCRIPT), *args, "--dir", directory],
                              env=environment or ENV, capture_output=True, text=True, timeout=8)

    def test_each_command_registers_current_files_without_mcp(self):
        # Exercise the real socket framing, with deliberately fragmented replies.
        with tempfile.TemporaryDirectory(prefix="progress-ipc-", dir="/tmp") as directory:
            socket_path = str(Path(directory) / "runtime.sock")
            requests, errors = [], []
            def receive(connection, size):
                data = b""
                while len(data) < size:
                    chunk = connection.recv(size - len(data))
                    if not chunk:
                        raise RuntimeError("incomplete request")
                    data += chunk
                return data
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(socket_path)
                server.listen()
                server.settimeout(5)
                def serve():
                    try:
                        for _ in range(3):
                            connection, _ = server.accept()
                            with connection:
                                connection.settimeout(5)
                                size = struct.unpack(">I", receive(connection, 4))[0]
                                request = json.loads(receive(connection, size))
                                args = request["params"]["arguments"]
                                # Files exist and are complete before registration.
                                requests.append((request, json.loads(Path(args["jsonPath"]).read_text())))
                                self.assertTrue(Path(args["htmlPath"]).is_file())
                                response = json.dumps({"version": 1, "id": request["id"],
                                    "result": {"sessionID": "fixture", "progress": args}}).encode()
                                framed = struct.pack(">I", len(response)) + response
                                for offset in range(0, len(framed), 7):
                                    connection.sendall(framed[offset:offset + 7])
                    except BaseException as error:
                        errors.append(error)
                worker = threading.Thread(target=serve)
                worker.start()
                environment = dict(ENV, CHAUFFEUR_SOCKET=socket_path,
                                   CHAUFFEUR_SESSION_TOKEN="fixture-private-token")
                try:
                    for command in [("init", "--title", "Fixture", "--phase", "Build"),
                                    ("now", "Implementing"), ("show",)]:
                        result = self.run_panel(directory, *command, environment=environment)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn("Registered in Chauffeur", result.stderr)
                        self.assertNotIn("fixture-private-token", result.stdout + result.stderr)
                finally:
                    worker.join(timeout=6)
                self.assertFalse(worker.is_alive())
                self.assertFalse(errors, errors)
            self.assertEqual(len(requests), 3)
            self.assertEqual(requests[1][1]["now"], "Implementing")
            for request, _ in requests:
                self.assertEqual(request["method"], "registerProgress")
                self.assertEqual(request["params"]["token"], "fixture-private-token")
                self.assertNotIn("sessionID", request["params"]["arguments"])
            for path in Path(directory).glob("*.*"):
                if path.is_file():
                    self.assertNotIn("fixture-private-token", path.read_text())

    def test_unavailable_runtime_keeps_panel_and_retries_later(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(ENV, CHAUFFEUR_SOCKET=str(Path(directory) / "missing.sock"),
                               CHAUFFEUR_SESSION_TOKEN="fixture-private-token")
            first = self.run_panel(directory, "init", "--title", "Fixture", "--phase", "Build", environment=environment)
            second = self.run_panel(directory, "now", "Still working", environment=environment)
            for result in [first, second]:
                self.assertEqual(result.returncode, 0)
                self.assertIn("could not register with Chauffeur", result.stderr)
                self.assertNotIn("fixture-private-token", result.stdout + result.stderr)
            self.assertEqual(json.loads((Path(directory) / "progress.json").read_text())["now"], "Still working")

    def test_bad_runtime_replies_preserve_local_updates_and_do_not_leak_credentials(self):
        for mode in ["rejected", "wrong-id", "oversized", "truncated"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="progress-ipc-", dir="/tmp") as directory:
                socket_path = str(Path(directory) / "runtime.sock")
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                    server.bind(socket_path)
                    server.listen()
                    server.settimeout(5)
                    errors = []
                    def serve():
                        try:
                            connection, _ = server.accept()
                            with connection:
                                connection.settimeout(5)
                                data = b""
                                while len(data) < 4:
                                    data += connection.recv(4 - len(data))
                                size = struct.unpack(">I", data)[0]
                                data = b""
                                while len(data) < size:
                                    chunk = connection.recv(size - len(data))
                                    if not chunk:
                                        raise RuntimeError("incomplete request")
                                    data += chunk
                                request = json.loads(data)
                                if mode == "oversized":
                                    connection.sendall(struct.pack(">I", 65_537))
                                elif mode == "truncated":
                                    connection.sendall(struct.pack(">I", 20) + b"{}")
                                else:
                                    reply = {"version": 1, "id": request["id"] if mode == "rejected" else "other",
                                             "error": {"message": "fixture-private-token"}}
                                    body = json.dumps(reply).encode()
                                    connection.sendall(struct.pack(">I", len(body)) + body)
                        except BaseException as error:
                            errors.append(error)
                    worker = threading.Thread(target=serve)
                    worker.start()
                    try:
                        result = self.run_panel(directory, "init", "--title", "Fixture", "--phase", "Build",
                            environment=dict(ENV, CHAUFFEUR_SOCKET=socket_path, CHAUFFEUR_SESSION_TOKEN="fixture-private-token"))
                    finally:
                        worker.join(timeout=6)
                    self.assertFalse(worker.is_alive())
                    self.assertFalse(errors, errors)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Panel is available locally", result.stderr)
                self.assertNotIn("fixture-private-token", result.stdout + result.stderr)
                self.assertTrue((Path(directory) / "progress.json").is_file())

    def test_default_directories_isolate_sessions_but_preserve_standalone_location(self):
        import importlib.util
        import hashlib
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location("progress", SCRIPT)
        progress = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(progress)
        with patch.dict(os.environ, ENV, clear=True):
            original = progress.default_dir()
            cwd = Path.cwd().resolve()
            digest = hashlib.sha256(os.fsencode(str(cwd))).hexdigest()[:12]
            self.assertTrue(original.endswith(f"{cwd.name}-{digest}"))
            os.environ["CHAUFFEUR_SESSION_ID"] = "first"
            first = progress.default_dir()
            os.environ["CHAUFFEUR_SESSION_ID"] = "second"
            second = progress.default_dir()
            self.assertEqual(len({original, first, second}), 3)
            os.environ["PROGRESS_DIR"] = "/explicit/panel"
            self.assertEqual(progress.default_dir(), "/explicit/panel")


if __name__ == "__main__":
    unittest.main()
