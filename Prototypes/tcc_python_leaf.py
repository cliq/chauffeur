"""Same file-access experiment as the native leaf, through a real Python binary."""
import ctypes
import json
import os
from pathlib import Path
import signal
import sys
import time

directory, name = Path(sys.argv[1]), sys.argv[2]
signal.alarm(600)
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
responsible = lib.responsibility_get_pid_responsible_for_pid
responsible.argtypes, responsible.restype = [ctypes.c_int], ctypes.c_int


def write(label, row):
    temp = directory / f"{label}.tmp"
    temp.write_text(json.dumps(row))
    temp.replace(directory / f"{label}.json")


def record(label):
    write(label, dict(pid=os.getpid(), ppid=os.getppid(), responsible=responsible(os.getpid())))


def access(phase):
    config = directory / "access-path.txt"
    if not config.exists():
        return
    error = 0
    fd, count = None, -1
    try:
        fd = os.open(config.read_text(), os.O_RDONLY)
        count = len(os.read(fd, 1))
    except OSError as exc:
        error = exc.errno
    finally:
        if fd is not None:
            os.close(fd)
    write("access-" + phase, dict(pid=os.getpid(), opened=fd is not None, bytes_read=count, errno=error))


record(name)
if name == "pane" and not (directory / "access-after-only").exists():
    access("before")
if name in ("later", "after-replacement") or name.startswith("alive-"):
    access(name)
for _ in range(1200):
    if (directory / "sample-after-exit").exists():
        record(name + "-after")
        if name == "pane":
            access("after")
        break
    time.sleep(0.1)
time.sleep(120)
