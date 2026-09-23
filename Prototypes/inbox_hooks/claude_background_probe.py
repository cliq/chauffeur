#!/usr/bin/env python3
"""Claude Code background-command probe (TUI, mock Messages API, no account).

The mock starts a `run_in_background` Bash command, then ends the turn. The probe
records whether Claude starts a new turn by itself when the command exits, what
that turn's input carries, and what the Stop and UserPromptSubmit hooks report
(`background_tasks`). Data in /tmp/clb; tmux socket /tmp/clb.sock.
"""
import json, os, pathlib, shutil, subprocess, sys, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import claude_mock_api

root = pathlib.Path('/tmp/clb'); shutil.rmtree(root, ignore_errors=True)
work = root / 'work'; work.mkdir(parents=True)
MARK = root / 'bg-done'

def decide(body):
    if not body.get('tools'): return 0, [{'type': 'text', 'text': 'title'}]
    flat = json.dumps(body['messages'][-1:])
    if 'task-notification' in flat or 'BG_DONE' in flat:
        return 0, [{'type': 'text', 'text': 'WOKE_ON_BACKGROUND_EXIT'}]
    used = [b for m in body['messages'] if m['role'] == 'assistant' and isinstance(m['content'], list) for b in m['content'] if b.get('type') == 'tool_use']
    if not used:
        return 0, [{'type': 'tool_use', 'name': 'Bash', 'input': {'command': f'sleep 6; touch {MARK}; echo BG_DONE', 'description': 'Wait for workers', 'run_in_background': True}}]
    return 0, [{'type': 'text', 'text': 'WAITING_FOR_BACKGROUND'}]

server, requests = claude_mock_api.serve(decide, log=(root / 'requests.jsonl').open('a'))
config = root / 'config'
claude_mock_api.profile(config, server.server_port, allow=['Bash'], trusted=[work])
hook = root / 'hook.py'
hook.write_text('import sys,json,pathlib\np=json.load(sys.stdin)\npathlib.Path(__file__).with_name("hooks.jsonl").open("a").write(json.dumps(p)+"\\n")\n')
settings = json.loads((config / 'settings.json').read_text())
settings['hooks'] = {e: [{'hooks': [{'type': 'command', 'command': f'/usr/bin/python3 {hook}'}]}] for e in ['Stop', 'UserPromptSubmit', 'PostToolUse']}
(config / 'settings.json').write_text(json.dumps(settings))
claude = shutil.which('claude') or str(pathlib.Path.home() / '.local/bin/claude')
T = ['tmux', '-S', '/tmp/clb.sock', '-f', '/dev/null']
subprocess.run(T + ['kill-server'], capture_output=True)
env = {'HOME': os.environ['HOME'], 'PATH': '/usr/bin:/bin', 'TERM': 'xterm-256color', 'CLAUDE_CONFIG_DIR': str(config)}
subprocess.run(T + ['new-session', '-d', '-s', 'c', '-x', '150', '-y', '45', '-c', str(work), 'env', *[f'{k}={v}' for k, v in env.items()], claude], check=True)
def screen(): return subprocess.run(T + ['capture-pane', '-p', '-t', 'c'], capture_output=True, text=True).stdout
def wait(pred, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        v = pred()
        if v: return v
        time.sleep(0.3)
try:
    assert wait(lambda: '? for shortcuts' in screen()), screen()
    subprocess.run(T + ['send-keys', '-t', 'c', '-l', 'BGWAIT start']); time.sleep(0.5); subprocess.run(T + ['send-keys', '-t', 'c', 'Enter'])
    wait(lambda: any('WAITING_FOR_BACKGROUND' in json.dumps(r) for r in requests) or 'WAITING_FOR_BACKGROUND' in screen(), 30)
    time.sleep(1); ended = len(requests); t0 = time.monotonic()
    wait(lambda: MARK.exists(), 20); time.sleep(8)
    woke = requests[ended:]
    print('background command finished:', MARK.exists(), '| requests after exit:', len(woke))
    for body in woke:
        print('  last input:', json.dumps(body['messages'][-1])[:400])
    for line in (root / 'hooks.jsonl').read_text().splitlines():
        p = json.loads(line)
        print('hook', p['hook_event_name'], 'background_tasks=', json.dumps(p.get('background_tasks'))[:300], 'prompt=', str(p.get('prompt', ''))[:80])
    print('\n'.join(l for l in screen().splitlines() if l.strip())[-900:])
finally:
    subprocess.run(T + ['kill-server'], capture_output=True); server.shutdown()
