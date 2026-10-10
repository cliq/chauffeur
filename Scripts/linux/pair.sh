#!/usr/bin/env bash
# Turns on remote access if needed and prints a pairing code for the iPhone or a Mac.
# The code is valid for 120 seconds or one pairing. Set CHAUFFEURCTL to use another chauffeurctl.
set -euo pipefail
ctl=${CHAUFFEURCTL:-chauffeurctl}
"$ctl" request setRemoteAccess '{"enabled":true}' >/dev/null
"$ctl" request beginPairing | python3 -c '
import json, sys
status = json.load(sys.stdin)
print("Address:", ", ".join(status["addresses"]) or status["hostName"])
print("Port:   ", status["port"])
print("Code:   ", status["pairing"]["code"], "(expires in 120 s)")
print("Key fingerprint:", status["keyFingerprint"])'
