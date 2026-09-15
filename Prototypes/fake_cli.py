#!/usr/bin/env python3
"""Test-only adapter fixture. Does not contact any provider or read credentials."""
import json
import os
from pathlib import Path
import runpy
import sys

if "--version" in sys.argv:
    print("codex-cli 0.154.0")  # Exercises the baseline adapter's flag path.
elif "--help" in sys.argv:
    print("Fixture: --add-dir --resume --mcp-config --settings --session-id")
else:
    session_id = os.environ["CHAUFFEUR_SESSION_ID"]
    path = Path.cwd() / (".chauffeur-fixture-" + session_id + ".json")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump({"pid": os.getpid(), "sessionID": session_id,
                   "arguments": sys.argv[1:],
                   "configurationPath": os.environ.get("CODEX_HOME") or os.environ.get("CLAUDE_CONFIG_DIR"),
                   "token": os.environ["CHAUFFEUR_SESSION_TOKEN"],
                   "inheritedAPIKey": "OPENAI_API_KEY" in os.environ or "ANTHROPIC_API_KEY" in os.environ}, handle)
    runpy.run_path(str(Path(__file__).with_name("fake_tui.py")), run_name="__main__")
