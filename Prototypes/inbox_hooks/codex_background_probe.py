#!/usr/bin/env python3
"""Codex background-command probe (TUI, mock Responses provider, no account).

Answers two questions for a "background waiter" coordinator design:
1. If the model starts a long command that keeps running (unified exec returns a
   session ID) and then ends its turn, does Codex start a new turn by itself when
   that command exits?
2. Can a sandboxed command connect to a Unix socket outside the workspace?
   (`-s workspace-write` and `-s read-only`), which the waiter needs to reach the
   Chauffeur runtime.

  codex_background_probe.py SANDBOX     # danger-full-access | workspace-write | read-only
Prints the observed requests and exits; tmux socket /tmp/cxb.sock, data in /tmp/cxb/SANDBOX.
"""
import http.server, json, os, pathlib, socket, subprocess, sys, threading, time

BIN = os.environ.get('CODEX_BIN', '/opt/homebrew/bin/codex')
sandbox = sys.argv[1] if len(sys.argv) > 1 else 'workspace-write'
run = pathlib.Path('/tmp/cxb') / sandbox
subprocess.run(['rm', '-rf', str(run)]); home = run / 'home'; work = run / 'work'
home.mkdir(parents=True); work.mkdir()
# A Unix socket outside the workspace, standing in for the Chauffeur runtime.
sock_path = str(pathlib.Path('/tmp/cxb') / f'{sandbox}.sock')
try: os.unlink(sock_path)
except FileNotFoundError: pass
listener = socket.socket(socket.AF_UNIX); listener.bind(sock_path); listener.listen(4)
connections = []
def accept():
    while True:
        try: c, _ = listener.accept(); connections.append(time.monotonic()); c.sendall(b'PONG\n'); c.close()
        except OSError: return
threading.Thread(target=accept, daemon=True).start()

requests, decisions, lock = [], [], threading.Lock()
def text(item): return ' '.join(c.get('text', '') for c in item.get('content', []) if isinstance(c, dict))
def decide(body, n):
    items = body.get('input', [])
    if not body.get('tools'): return {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'title'}]}
    starts = [i for i, it in enumerate(items) if it.get('role') == 'user' and text(it).startswith(('BGWAIT', 'SOCK'))]
    prompt = text(items[starts[-1]]) if starts else ''
    after = items[starts[-1] + 1:] if starts else []
    calls = [i for i in after if i.get('type') == 'function_call']
    def call(cmd, **extra): return {'type': 'function_call', 'call_id': f'c{n}', 'name': 'exec_command', 'arguments': json.dumps({'cmd': cmd, **extra})}
    def say(t): return {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': t}]}
    if prompt.startswith('SOCK') and not calls:
        return call(f"python3 -c \"import socket; s=socket.socket(socket.AF_UNIX); s.connect('{sock_path}'); print('SOCKET', s.recv(5))\"")
    if prompt.startswith('BGWAIT') and not calls:
        # Long enough to outlive the turn; yield quickly so unified exec backgrounds it.
        return call(f'sleep 8; touch {run}/bg-done; echo BG_DONE', yield_time_ms=500)
    return say(f'END {n}')

class Mock(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{"data":[]}')
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.headers.get('Content-Encoding') == 'zstd': raw = subprocess.run(['zstd', '-d', '--stdout'], input=raw, capture_output=True).stdout
        body = json.loads(raw)
        with lock: requests.append((time.monotonic(), body)); n = len(requests)
        if n == 1: (run / 'first-request.json').write_text(json.dumps(body, indent=1))
        item = decide(body, n); item.setdefault('id', f'i{n}'); item.setdefault('status', 'completed')
        decisions.append((n, bool(body.get('tools')), item.get('name') or item.get('type'), json.loads(item.get('arguments', '{}')).get('cmd', '')[:40] if item.get('arguments') else text(item)[:40]))
        ev = [{'type': 'response.created', 'response': {'id': f'r{n}', 'object': 'response', 'status': 'in_progress', 'output': []}},
              {'type': 'response.output_item.added', 'output_index': 0, 'item': item}, {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
              {'type': 'response.completed', 'response': {'id': f'r{n}', 'object': 'response', 'status': 'completed', 'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
        out = ''.join(f'event: {e["type"]}\ndata: {json.dumps(e)}\n\n' for e in ev).encode()
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Mock); threading.Thread(target=server.serve_forever, daemon=True).start()
(home / 'config.toml').write_text(f'''model = "gpt-5.4"
model_provider = "probe"
[model_providers.probe]
name = "Probe"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
[features]
enable_request_compression = false
shell_snapshot = false
[projects.{json.dumps(str(work))}]
trust_level = "trusted"
[notice]
hide_full_access_warning = true
[notice.model_migrations]
"gpt-5.4" = "gpt-6-sol"
''')
T = ['tmux', '-S', '/tmp/cxb.sock', '-f', '/dev/null']
subprocess.run(T + ['kill-server'], capture_output=True)
env = {k: v for k, v in os.environ.items() if not any(s in k for s in ['TOKEN', 'API_KEY', 'CODEX', 'CHAUFFEUR', 'CLAUDE'])}; env['CODEX_HOME'] = str(home)
subprocess.run(T + ['new-session', '-d', '-s', 'p', '-x', '160', '-y', '45', '-c', str(work), BIN, '-C', str(work), '-s', sandbox, '-a', 'never'], env=env, check=True)
def screen(): return subprocess.run(T + ['capture-pane', '-p', '-t', 'p'], capture_output=True, text=True).stdout
def keys(v):
    """Types a prompt and presses Enter until the TUI sends a model request."""
    before = len(requests)
    subprocess.run(T + ['send-keys', '-t', 'p', '-l', v]); time.sleep(0.5)
    for _ in range(6):
        subprocess.run(T + ['send-keys', '-t', 'p', 'Enter'])
        if wait(lambda: len(requests) > before, 3): return
    raise SystemExit('prompt was not submitted:\n' + screen())
def wait(pred, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        v = pred()
        if v: return v
        time.sleep(0.3)
    return None
try:
    wait(lambda: 'Ask Codex to do anything' in screen())
    keys('SOCK connect')
    wait(lambda: any(i.get('type') == 'function_call_output' for _, b in requests for i in b.get('input', [])), 30)
    time.sleep(2)
    sock_out = next((i.get('output') for _, b in reversed(requests) for i in b.get('input', []) if i.get('type') == 'function_call_output' and 'SOCKET' in json.dumps(i) or (i.get('type') == 'function_call_output' and 'socket' in json.dumps(i).lower())), None)
    print('sandbox', sandbox, 'socket connections', len(connections), 'output', (sock_out or '')[-300:].replace('\n', ' | '))
    start = len(requests)
    keys('BGWAIT start')
    ended = wait(lambda: any(i.get('type') == 'function_call_output' for _, b in requests[start:] for i in b.get('input', [])), 30)
    t_end = time.monotonic()
    wait(lambda: 'Ask Codex to do anything' in screen() and 'Working' not in screen(), 20)
    print('turn ended; background command still running expected. requests so far', len(requests) - start)
    first_output = [i.get('output') for _, b in requests[start:] for i in b.get('input', []) if i.get('type') == 'function_call_output'][-1:]
    first_output = first_output[0] if first_output else ''
    print('exec output at yield:', first_output[-200:].replace('\n', ' | '))
    before = len(requests)
    time.sleep(20)
    woke = requests[before:]
    print('requests after the command should have exited:', len(woke), 'command finished:', (run / 'bg-done').exists())
    for t, b in woke:
        print('  +%.1fs' % (t - t_end), [ (i.get('role') or i.get('type'), text(i)[:120] or str(i.get('output', ''))[:120]) for i in b['input'][-3:]])
    print('decisions', decisions)
    print('screen tail:\n' + '\n'.join(l for l in screen().splitlines() if l.strip())[-1200:])
finally:
    subprocess.run(T + ['kill-server'], capture_output=True); server.shutdown(); listener.close()
