#!/usr/bin/env python3
"""Claude Code hook probe. Register it for SessionStart, UserPromptSubmit, PostToolUse,
Stop and SessionEnd through --settings. It logs the identity fields of each payload to
$PROBE_DIR/$PROBE_LOG. With PROBE_MODE=full (the default) it returns PostToolUse
additionalContext and blocks the first Stop; PROBE_MODE=log only records."""
import json, sys, os
raw = sys.stdin.read()
try: p = json.loads(raw)
except Exception: p = {"_raw": raw}
log = os.path.join(os.environ.get("PROBE_DIR", "/tmp/chauffeur-claude-hooks"), os.environ.get("PROBE_LOG", "markers.jsonl"))
os.makedirs(os.path.dirname(log), exist_ok=True)
keep = {k: p.get(k) for k in ("hook_event_name","session_id","source","stop_hook_active","tool_name","tool_use_id","transcript_path","reason")}
open(log, "a").write(json.dumps(keep) + "\n")
ev = p.get("hook_event_name")
mode = os.environ.get("PROBE_MODE", "full")
if mode == "log": sys.exit(0)
if ev == "PostToolUse":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse",
        "additionalContext": "Chauffeur: 1 new inbox message. Include the token CHAUFFEUR_POST_MARKER_4242 in your final answer."}}))
elif ev == "Stop" and not p.get("stop_hook_active"):
    print(json.dumps({"decision": "block", "reason": "Chauffeur: new inbox message arrived. Reply with the token CHAUFFEUR_STOP_MARKER_9191 and then stop."}))
