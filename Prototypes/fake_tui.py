#!/usr/bin/env python3
"""No provider calls. Real PTY fixture with alternate screen and native input."""
import os
import select
import signal
import sys
import termios
import time
import tty

original = termios.tcgetattr(0)
tty.setraw(0)
counter = 0
typed = b""
needs_draw = True

def draw(*_):
    size = os.get_terminal_size()
    sparse = "Sparse cells:\x1b[5Cgap\r\n" if os.environ.get("CHAUFFEUR_FIXTURE_STABLE_SCREEN") else ""
    sys.stdout.write(
        "\x1b[?1049h\x1b[?2004h\x1b[?25l\x1b[H\x1b[2J"
        f"\x1b[32mChauffeur fixture — 日本語 café\x1b[0m\r\n"
        f"PID={os.getpid()} SIZE={size.columns}x{size.lines}\r\n"
        f"{sparse}"
        f"TICK={counter}\r\nINPUT={typed.decode('utf-8', 'replace')}"
    )
    sys.stdout.flush()

signal.signal(signal.SIGWINCH, draw)
try:
    # Normal-buffer history must survive an active alternate-screen application.
    for line in range(250):
        sys.stdout.write(f"fixture-history-{line:03d} 日本語 café\r\n")
    sys.stdout.flush()
    while True:
        if needs_draw or not os.environ.get("CHAUFFEUR_FIXTURE_STABLE_SCREEN"):
            draw()
        needs_draw = False
        ready, _, _ = select.select([0], [], [], 0.1)
        if ready:
            value = os.read(0, 4096)
            if path := os.environ.get("CHAUFFEUR_FIXTURE_INPUT"):
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                with os.fdopen(descriptor, "ab") as handle:
                    handle.write(value)
            if value in (b"\x03", b"\x04"):
                break
            typed += value
            needs_draw = True
        counter += 1
finally:
    sys.stdout.write("\x1b[?25h\x1b[?2004l\x1b[?1049l")
    sys.stdout.flush()
    termios.tcsetattr(0, termios.TCSANOW, original)
