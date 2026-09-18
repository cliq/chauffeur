#!/usr/bin/env python3
"""Measure responsibility; optional file-access checks can show TCC prompts.

Builds a disposable signed LSUIElement fixture in /private/tmp; uses unique
LaunchAgents and tmux sockets. Private JSON evidence stays in --artifacts.
Never resets TCC or answers consent dialogs. Run access cases one at a time.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

REPO = Path(__file__).resolve().parents[1]


def run(*args, check=True):
    return subprocess.run([str(a) for a in args], check=check, capture_output=True, text=True, timeout=60)


def wait_file(path, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return json.loads(path.read_text())
        time.sleep(0.1)
    raise RuntimeError(f"Missing probe output: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identity", required=True, help="Developer ID signing identity")
    parser.add_argument("--artifacts", type=Path, default=REPO / ".local/tcc-responsibility")
    cases = ["direct", "direct-gui", "launchservices", "agent-bare",
             "agent-bare-associated", "agent-embedded", "agent-embedded-associated",
             "agent", "agent-associated", "agent-open"]
    parser.add_argument("--case", choices=cases, help="Run just one named case")
    parser.add_argument("--access-file", type=Path,
                        help="Opt in to opening this file from a pane before/after owner exit; may prompt")
    parser.add_argument("--access-after-exit-only", action="store_true",
                        help="Skip access while owner lives, to avoid warming access caches")
    parser.add_argument("--adhoc-tool", action="store_true", help="Model a Homebrew tool with ad-hoc signing")
    args = parser.parse_args()
    args.artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
    root = Path(tempfile.mkdtemp(prefix="chauffeur-tcc-", dir="/private/tmp"))
    app = root / "Responsibility Probe.app"
    binary = app / "Contents/MacOS/probe"
    binary.parent.mkdir(parents=True)
    bundle = "dev.cliq.chauffeur.responsibility-probe"
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump(dict(CFBundleIdentifier=bundle, CFBundleExecutable="probe",
                          CFBundleName="Chauffeur Responsibility Probe", CFBundlePackageType="APPL",
                          CFBundleVersion="1", LSUIElement=True), file)
    run("xcrun", "clang", "-Wall", "-Wextra", "-framework", "AppKit",
        REPO / "Prototypes/responsibility_probe.m", "-o", binary)
    run("codesign", "--force", "--options", "runtime", "--sign", args.identity, app)
    bare = root / "bare-probe"
    shutil.copy2(binary, bare)
    run("codesign", "--force", "--options", "runtime", "--identifier", bundle + ".bare",
        "--sign", args.identity, bare)
    embedded = binary.parent / "worker"
    shutil.copy2(bare, embedded)
    leaf = root / "tool-probe"
    shutil.copy2(bare, leaf)
    tool_identifier = bundle + ".tool." + uuid.uuid4().hex
    run("codesign", "--force", "--options", "runtime", "--identifier", tool_identifier,
        "--sign", "-" if args.adhoc_tool else args.identity, leaf)
    run("codesign", "--force", "--options", "runtime", "--sign", args.identity, app)
    run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
        "-f", app)
    tmux = shutil.which("tmux")
    if not tmux:
        raise RuntimeError("tmux missing")
    lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    responsibility = lib.responsibility_get_pid_responsible_for_pid
    responsibility.argtypes = [ctypes.c_int]
    responsibility.restype = ctypes.c_int
    report = {"os": run("sw_vers").stdout, "root": str(root),
              "tool_identifier": tool_identifier, "adhoc_tool": args.adhoc_tool, "cases": {}}
    try:
        for case in cases:
            if args.case and case != args.case:
                continue
            directory = root / case
            directory.mkdir()
            if args.access_file:
                (directory / "access-path.txt").write_text(str(args.access_file.resolve()))
            if args.access_after_exit_only:
                (directory / "access-after-only").touch()
            job = f"dev.cliq.chauffeur.tcc-probe.{uuid.uuid4().hex}"
            target = f"gui/{os.getuid()}/{job}"
            pids = set()
            process = None
            is_agent = case.startswith("agent")
            try:
                owner_binary = bare if "bare" in case else embedded if "embedded" in case else binary
                command = [str(owner_binary),
                           "gui" if case == "direct-gui" else "plain", str(directory), tmux, "owner", str(leaf)]
                if case.startswith("direct"):
                    process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                elif case == "launchservices":
                    run("open", "-n", "-a", app, "--args", "gui", directory, tmux, "owner", leaf)
                else:
                    if case == "agent-open":
                        command = [str(binary), "open", str(directory), tmux, "owner", str(app), str(leaf)]
                    plist = dict(Label=job, ProgramArguments=command, RunAtLoad=True,
                                 AbandonProcessGroup=True, ProcessType="Interactive",
                                 LimitLoadToSessionType="Aqua", StandardErrorPath=str(directory / "stderr"))
                    if case.endswith("associated"):
                        plist["AssociatedBundleIdentifiers"] = [bundle]
                    path = directory / "agent.plist"
                    path.write_bytes(plistlib.dumps(plist))
                    run("launchctl", "bootstrap", f"gui/{os.getuid()}", path)
                rows = {name: wait_file(directory / f"{name}.json")
                        for name in ["owner", "plain", "pgroup", "daemon", "foundation", "pane"]}
                pids.update(row["pid"] for row in rows.values())
                server = int(run(tmux, "-S", directory / "tmux.sock", "display-message", "-p", "#{pid}").stdout)
                rows["server"] = {"pid": server, "responsible": responsibility(server)}
                for row in rows.values():
                    row["external_responsible"] = responsibility(row["pid"])
                access_before = (wait_file(directory / "access-before.json", 120)
                                 if args.access_file and not args.access_after_exit_only else None)
                os.kill(rows["owner"]["pid"], signal.SIGTERM)
                time.sleep(0.5)
                (directory / "sample-after-exit").touch()
                after = {name: wait_file(directory / f"{name}-after.json")
                         for name in ["plain", "pgroup", "daemon", "foundation", "pane"]}
                run(tmux, "-S", directory / "tmux.sock", "new-session", "-d", "-s", "later",
                    leaf, "leaf", directory, tmux, "later")
                after["later"] = wait_file(directory / "later.json")
                pids.add(after["later"]["pid"])
                after["server"] = {"pid": server, "responsible": responsibility(server)}
                # A new process with the same signed identity cannot be assumed
                # to adopt a server created by its previous incarnation.
                run("open", "-n", "-a", app, "--args", "hold", directory, tmux, "replacement")
                replacement = wait_file(directory / "replacement.json")
                pids.add(replacement["pid"])
                run(tmux, "-S", directory / "tmux.sock", "new-session", "-d", "-s", "replacement",
                    leaf, "leaf", directory, tmux, "after-replacement")
                adopted = wait_file(directory / "after-replacement.json")
                pids.add(adopted["pid"])
                report["cases"][case] = {"before": rows, "after_owner_exit": after,
                                         "replacement_owner": replacement, "pane_after_replacement": adopted}
                if args.access_file:
                    report["cases"][case]["access"] = {"before": access_before,
                        "after": wait_file(directory / "access-after.json", 120),
                        "new_pane": wait_file(directory / "access-later.json", 120),
                        "new_pane_after_replacement": wait_file(directory / "access-after-replacement.json", 120)}
                print(case, json.dumps(report["cases"][case]), flush=True)
            finally:
                if is_agent:
                    run("launchctl", "bootout", target, check=False)
                run(tmux, "-S", directory / "tmux.sock", "kill-server", check=False)
                # Include partial runs in cleanup; only PIDs recorded by this fixture.
                for path in directory.glob("*.json"):
                    pids.add(json.loads(path.read_text())["pid"])
                for pid in pids:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                if process:
                    process.wait(timeout=5)
    finally:
        (args.artifacts / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
        shutil.copytree(root, args.artifacts / root.name, ignore=shutil.ignore_patterns("*.sock"))
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
