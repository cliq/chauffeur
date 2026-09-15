#!/usr/bin/env python3
"""V1 fixture: private tmux server, two real PTY attachments, no user sessions."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

tmux = shutil.which("tmux")
assert tmux, "Install tmux before running V1"
fixture = str(Path(__file__).with_name("fake_tui.py").resolve())

def await_condition(probe, predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if predicate(value):
            return value
        time.sleep(0.05)
    raise AssertionError("Condition timed out")

with tempfile.TemporaryDirectory(prefix="chauffeur-v1-", dir="/tmp") as root:
    socket = root + "/tmux.sock"
    def run(*args):
        return subprocess.check_output([tmux, "-S", socket, "-f", "/dev/null", *args], text=True)
    def capture():
        return run("capture-pane", "-p", "-e", "-t", "fixture")
    def attach(cols, rows):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        env = dict(os.environ, TERM="xterm-256color")
        env.pop("TMUX", None)
        process = subprocess.Popen([tmux, "-S", socket, "attach-session", "-t", "fixture"], stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
        os.close(slave)
        return process, master
    def drain(fd, seconds=0.4):
        data = b""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.05)[0]:
                data += os.read(fd, 65536)
        return data
    clients = []
    try:
        run("new-session", "-d", "-s", "fixture", "-x", "90", "-y", "30", sys.executable, fixture)
        run("set-option", "-g", "status", "off")
        run("set-option", "-g", "history-limit", "200")
        initial = await_condition(capture, lambda s: "PID=" in s)
        identity = re.search(r"PID=(\d+)", initial)[1]
        first, fd = attach(90, 30)
        clients.append((first, fd))
        redraw = drain(fd)
        assert b"Chauffeur fixture" in redraw and "日本語".encode() in redraw
        os.write(fd, b"unsent input")
        await_condition(capture, lambda s: "INPUT=unsent input" in s)
        before = int(re.search(r"TICK=(\d+)", capture())[1])
        first.kill()
        first.wait(timeout=3)
        os.close(fd)
        clients.clear()
        detached = await_condition(capture, lambda s: int(re.search(r"TICK=(\d+)", s)[1]) > before + 3)
        assert f"PID={identity}" in detached
        second, fd = attach(110, 35)
        clients.append((second, fd))
        restored = drain(fd)
        assert b"Chauffeur fixture" in restored and b"unsent input" in restored
        await_condition(capture, lambda s: "SIZE=110x35" in s)
        assert f"PID={identity}" in capture()
        mode = run("display-message", "-p", "-t", "fixture", "#{alternate_on}|#{pane_in_mode}|#{history_size}").strip()
        assert mode.startswith("1|0|")
        os.write(fd, b" after attach")
        await_condition(capture, lambda s: "INPUT=unsent input after attach" in s)
        print(json.dumps({"fixture": "pass", "tmux": run("-V").strip(), "samePID": True, "detachedOutput": True, "unsentInputPreserved": True, "resize": "110x35", "alternateScreen": True, "unicode": True, "realCLIAccounts": "pending"}, indent=2))
    finally:
        for process, fd in clients:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=3)
            os.close(fd)
        subprocess.run([tmux, "-S", socket, "kill-server"], capture_output=True)
