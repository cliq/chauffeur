#!/usr/bin/env python3
"""Start and update a narrow, auto-refreshing implementation-progress panel.

The panel is a static HTML page (assets/index.html) that re-reads progress.js
every 2 seconds. State lives in progress.json next to it; every command rewrites
progress.js from that file, so agents never hand-edit JS.

Usage (DIR defaults to $PROGRESS_DIR, then a project-specific OS temp directory):
  progress.py init  [--dir DIR] --title T [--subtitle S] --phase "Title::detail" ... [--now TEXT] [--open]
  progress.py now   [--dir DIR] "what you are doing right now"
  progress.py phase [--dir DIR] PHASE STATE [--detail TEXT]        STATE: done|active|pending|blocked
  progress.py step  [--dir DIR] PHASE "step title" STATE            (adds the step if missing)
  progress.py show  [--dir DIR]
  progress.py open  [--dir DIR]
PHASE is a 1-based index or a case-insensitive prefix of the phase title.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import webbrowser
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "..", "assets", "index.html")
STATES = ("done", "active", "pending", "blocked")


def default_dir():
    if os.environ.get("PROGRESS_DIR"):
        return os.environ["PROGRESS_DIR"]
    cwd = Path.cwd().resolve()
    digest = hashlib.sha256(os.fsencode(str(cwd))).hexdigest()[:12]
    return str(Path(tempfile.gettempdir()) / "implementation-progress" / f"{cwd.name or 'project'}-{digest}")


def load(d):
    try:
        with open(os.path.join(d, "progress.json"), encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        sys.exit(f"no panel in {d}; run init with the same --dir first")


def atomic_write(path, text):
    # Readers see either the old file or the complete new one during refresh.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         delete=False) as f:
            temporary = Path(f.name)
            f.write(text)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def save(d, data):
    data["schemaVersion"] = 1
    phases = data.get("phases", [])
    completed = 0.0
    for phase in phases:
        if phase["state"] == "done":
            completed += 1
        elif phase["state"] == "active":
            steps = phase.get("steps", [])
            completed += sum(step["state"] == "done" for step in steps) / len(steps) if steps else 0.5
    # Match the panel's Math.round (Python round uses ties-to-even).
    data["percentComplete"] = int(100 * completed / len(phases) + 0.5) if phases else 0
    data["updated"] = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    atomic_write(Path(d) / "progress.json", json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    atomic_write(Path(d) / "progress.js", "window.IMPLEMENTATION_PROGRESS = " + json.dumps(data) + ";\n")


def find_phase(data, key):
    phases = data["phases"]
    if key.isdigit():
        i = int(key) - 1
        if 0 <= i < len(phases):
            return phases[i]
        sys.exit(f"no phase #{key} (have {len(phases)})")
    hits = [p for p in phases if p["title"].lower().startswith(key.lower())]
    if len(hits) != 1:
        sys.exit(f"phase '{key}' matched {len(hits)} phases; use an index or a longer prefix")
    return hits[0]


def check_state(s):
    if s not in STATES:
        sys.exit(f"state must be one of {', '.join(STATES)}")
    return s


def cmd_init(a):
    if Path(a.dir, "progress.json").exists() and not a.force:
        sys.exit(f"panel already exists in {a.dir}; use show/open to resume or init --force to reset")
    phases = []
    for spec in a.phase or []:
        title, _, detail = spec.partition("::")
        if not title.strip():
            sys.exit("phase titles must not be empty")
        phases.append({"title": title.strip(), "detail": detail.strip(), "state": "pending", "steps": []})
    os.makedirs(a.dir, exist_ok=True)
    shutil.copyfile(TEMPLATE, os.path.join(a.dir, "index.html"))
    if phases:
        phases[0]["state"] = "active"
    save(a.dir, {"title": a.title, "subtitle": a.subtitle or "", "now": a.now or "Starting", "phases": phases})
    print(os.path.join(a.dir, "index.html"))
    if a.open:
        cmd_open(a)


def cmd_open(a):
    path = Path(a.dir, "index.html").resolve()
    if not path.is_file():
        sys.exit(f"no panel in {a.dir}; run init with the same --dir first")
    uri = path.as_uri()
    try:
        opened = webbrowser.open(uri)
    except (webbrowser.Error, OSError):
        opened = False
    if not opened:
        print(f"Could not launch a browser. Open this file manually: {uri}", file=sys.stderr)


def cmd_now(a):
    data = load(a.dir)
    data["now"] = a.text
    save(a.dir, data)


def cmd_phase(a):
    data = load(a.dir)
    p = find_phase(data, a.phase)
    p["state"] = check_state(a.state)
    if a.detail is not None:
        p["detail"] = a.detail
    if a.state == "done":
        for s in p.get("steps", []):
            if s["state"] != "blocked":
                s["state"] = "done"
    save(a.dir, data)


def cmd_step(a):
    data = load(a.dir)
    p = find_phase(data, a.phase)
    steps = p.setdefault("steps", [])
    hit = next((s for s in steps if s["title"].lower() == a.title.lower()), None)
    if hit is None:
        hit = {"title": a.title, "state": "pending"}
        steps.append(hit)
    hit["state"] = check_state(a.state)
    if p["state"] == "pending":
        p["state"] = "active"
    save(a.dir, data)


def cmd_show(a):
    data = load(a.dir)
    mark = {"done": "✓", "active": "▶", "pending": "·", "blocked": "✗"}
    print(f"{data['title']} — now: {data.get('now','')}")
    for i, p in enumerate(data["phases"], 1):
        print(f"{mark[p['state']]} {i}. {p['title']}")
        for s in p.get("steps", []):
            print(f"     {mark[s['state']]} {s['title']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--dir", default=default_dir())

    sp = sub.add_parser("init"); common(sp)
    sp.add_argument("--title", required=True); sp.add_argument("--subtitle")
    sp.add_argument("--phase", action="append", required=True, help='"Title::detail", repeatable, in order')
    sp.add_argument("--force", action="store_true", help="replace an existing panel and reset its progress")
    sp.add_argument("--now"); sp.add_argument("--open", action="store_true"); sp.set_defaults(fn=cmd_init)
    sp = sub.add_parser("now"); common(sp); sp.add_argument("text"); sp.set_defaults(fn=cmd_now)
    sp = sub.add_parser("phase"); common(sp); sp.add_argument("phase"); sp.add_argument("state")
    sp.add_argument("--detail"); sp.set_defaults(fn=cmd_phase)
    sp = sub.add_parser("step"); common(sp); sp.add_argument("phase"); sp.add_argument("title")
    sp.add_argument("state"); sp.set_defaults(fn=cmd_step)
    sp = sub.add_parser("show"); common(sp); sp.set_defaults(fn=cmd_show)
    sp = sub.add_parser("open"); common(sp); sp.set_defaults(fn=cmd_open)
    a = ap.parse_args()
    a.dir = str(Path(a.dir).expanduser().resolve())
    try:
        a.fn(a)
    except (OSError, ValueError) as exc:
        ap.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    main()
