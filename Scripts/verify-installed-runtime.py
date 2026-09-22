#!/usr/bin/env python3
"""Wait for the installed Release app's verified, MCP-ready runtime."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time


def main():
    app = Path(sys.argv[1]).resolve()
    executable = app / 'Contents/MacOS/ChauffeurRuntime'
    control = app / 'Contents/MacOS/chauffeurctl'
    root = (Path.home() / 'Library/Application Support/Chauffeur').resolve()
    expected = {
        'build': 'Release',
        'executablePath': str(executable.resolve()),
        'executableDigest': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'dataRoot': str(root),
    }
    deadline = time.monotonic() + 90
    last_state = 'Background service has not connected'
    while time.monotonic() < deadline:
        try:
            result = subprocess.run(
                [str(control), 'status', '--socket', str(root / 'runtime/runtime.sock')],
                capture_output=True, text=True, timeout=3, check=True)
            status = json.loads(result.stdout)
            if not all((status.get('identity') or {}).get(key) == value for key, value in expected.items()):
                last_state = 'Background service is still running a different build or installation'
            elif not status.get('mcpEndpoint'):
                last_state = 'Updated runtime is starting its MCP server'
            else:
                print(f"Verified installed Release runtime (PID {status['pid']}); MCP ready")
                return
        except (subprocess.SubprocessError, OSError, ValueError):
            last_state = 'Waiting for the installed app to register and start its background service'
        time.sleep(0.5)
    raise SystemExit(f'{last_state}. Check Runtime settings and Login Items; installation verification failed.')


if __name__ == '__main__':
    main()
