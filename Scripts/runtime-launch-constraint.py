#!/usr/bin/env python3
"""Bind a bundled LaunchAgent to its already-signed runtime executable."""
import pathlib
import plistlib
import re
import subprocess
import sys

contents = pathlib.Path(sys.argv[1])
runtime = contents / "MacOS/ChauffeurRuntime"
signature = subprocess.run(
    ["/usr/bin/codesign", "-d", "--verbose=4", str(runtime)],
    capture_output=True, text=True, check=True,
)
match = re.search(r"^CDHash=([0-9a-f]{40})$", signature.stderr, re.MULTILINE)
if match is None:
    raise SystemExit("Cannot determine the signed runtime's code hash")
path = pathlib.Path(sys.argv[2])
with path.open("rb") as source:
    job = plistlib.load(source)
team = re.search(r"^TeamIdentifier=([A-Z0-9]+)$", signature.stderr, re.MULTILINE)
identifier = re.search(r"^Identifier=(.+)$", signature.stderr, re.MULTILINE)
if team and identifier:
    # Certificate signatures have a stable team/identifier across builds.
    job["SpawnConstraint"] = {"team-identifier": team[1], "signing-identifier": identifier[1]}
else:
    job["SpawnConstraint"] = {"cdhash": bytes.fromhex(match[1])}
with path.open("wb") as destination:
    plistlib.dump(job, destination, sort_keys=False)
