#!/usr/bin/env python3
"""Private terminal pointer fixture; never contacts a provider."""
import json
import os
from pathlib import Path
import select
import signal
import sys
import termios
import tty

if '--version' in sys.argv:
    print('codex-cli 0.154.0'); raise SystemExit
if '--help' in sys.argv:
    print('Fixture: --add-dir --resume'); raise SystemExit

config = json.loads((Path(os.environ['CODEX_HOME']) / 'pointer.json').read_text())
original = termios.tcgetattr(0)
tty.setraw(0)
mouse = False


def draw(*_):
    sys.stdout.write('\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J'
                     'Chauffeur pointer fixture\r\n\r\n'
                     + config['origin'] + '/implicit\r\n'
                     + '\x1b]8;;' + config['origin'] + '/explicit\x1b\\Open explicit fixture\x1b]8;;\x1b\\\r\n\r\n'
                     + 'native mouse selection\r\n\r\n'
                     + ('Mouse reporting enabled' if mouse else 'Mouse reporting disabled') + '\r\n'
                     + 'F6 enables tracking; F7 disables tracking.\r\n')
    sys.stdout.flush()


signal.signal(signal.SIGWINCH, draw)
try:
    draw()
    while True:
        ready, _, _ = select.select([0], [], [], 0.1)
        if not ready:
            continue
        value = os.read(0, 4096)
        with open(config['inputFile'], 'ab') as log:
            log.write(value)
        if value in (b'\x03', b'\x04'):
            break
        if b'\x1b[17~' in value:
            mouse = True
            sys.stdout.write('\x1b[?1002h\x1b[?1006h'); draw()
        elif b'\x1b[18~' in value:
            mouse = False
            sys.stdout.write('\x1b[?1002l\x1b[?1006l'); draw()
finally:
    sys.stdout.write('\x1b[?1002l\x1b[?1006l\x1b[?25h\x1b[?1049l')
    sys.stdout.flush()
    termios.tcsetattr(0, termios.TCSANOW, original)
