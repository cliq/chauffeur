#!/usr/bin/env python3
"""Idle coordinators through the real runtime and the real Claude Code and Codex
TUIs, with scripted local mock providers (no accounts, no paid inference).

Checks:
- Claude coordinator: delegates to a Codex worker, starts `wait-for-work` in the
  background from discovery's `waitCommand` (pre-approved by Chauffeur, no prompt),
  and ends its turn. The tab says "Waiting for workers"; the model gets no
  requests while the worker runs. The worker's result wakes it exactly once, and
  the waiter's output file holds the result.
- Codex coordinator: delegates and ends its turn. When the worker reports, Chauffeur
  types one "Chauffeur: 1 new worker result" prompt; the coordinator reads its inbox.
- Codex status: a long Codex turn shows "Running", not "Turn finished".

  swift build && Prototypes/coordinator_wait_smoke.py
"""
import argparse, http.server, json, os, re, shutil, socket, struct, subprocess, sys, tempfile, threading, time, uuid
from pathlib import Path

os.umask(0o077)
repo = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repo / 'Prototypes/inbox_hooks'))
import claude_mock_api

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--codex', default=shutil.which('codex'))
parser.add_argument('--claude', default=shutil.which('claude'))
parser.add_argument('--runtime', type=Path, default=repo / '.build/debug/ChauffeurRuntime')
parser.add_argument('--artifacts', type=Path, default=repo / '.local/coordinator-wait-artifacts')
options = parser.parse_args()
tmux = shutil.which('tmux')
assert options.codex and options.claude and tmux
artifacts = options.artifacts.resolve(); artifacts.mkdir(parents=True, exist_ok=True)
MARKERS = ('DELEGATE', 'WORKER', 'Chauffeur:')
def uid(): return str(uuid.uuid4()).upper()
class Fatal(Exception): pass
lock = threading.Lock()
issued = []  # (provider, tool, prompt)

# ------------------------------------------------------------ Claude coordinator
def cblocks(m): return m['content'] if isinstance(m['content'], list) else [{'type': 'text', 'text': m['content']}]
def claude_decide(body):
    if not body.get('tools'): return 0, [{'type': 'text', 'text': 'title'}]
    msgs = body['messages']
    start = max((i for i, m in enumerate(msgs) if m['role'] == 'user' and any(b.get('type') == 'text' and b['text'].strip().startswith('DELEGATE') for b in cblocks(m))), default=None)
    if start is None: return 0, [{'type': 'text', 'text': 'idle'}]
    prompt = next(b['text'].strip() for b in cblocks(msgs[start]) if b.get('type') == 'text' and b['text'].strip().startswith('DELEGATE'))
    turn = msgs[start:]
    uses = [b for m in turn if m['role'] == 'assistant' for b in cblocks(m) if b.get('type') == 'tool_use']
    names = [b['name'] for b in uses]
    results = {b.get('tool_use_id'): json.dumps(b.get('content')) for m in turn if m['role'] == 'user' for b in cblocks(m) if b.get('type') == 'tool_result'}
    last = json.dumps(msgs[-1])
    def tool(name, value):
        with lock: issued.append(('claude', name, prompt))
        return 0, [{'type': 'tool_use', 'name': name, 'input': value}]
    if 'task-notification' in last:
        path = re.search(r'<output-file>([^<]+)</output-file>', last).group(1)
        return tool('Read', {'file_path': path})
    if names and names[-1] == 'Read':
        with lock: issued.append(('claude', 'woke-read', results.get(uses[-1].get('id'), '')))
        return 0, [{'type': 'text', 'text': 'RESULT_HANDLED'}]
    if 'mcp__chauffeur__chauffeur_discover' not in names:
        return tool('mcp__chauffeur__chauffeur_discover', {})
    if 'mcp__chauffeur__chauffeur_delegate' not in names:
        _, preset, folder = prompt.split(' ')
        return tool('mcp__chauffeur__chauffeur_delegate', {'task': 'WORKER report', 'presetID': preset, 'folderID': folder, 'shareCheckout': True, 'retryKey': 'claude-worker'})
    if 'Bash' not in names:
        discover_id = next(b['id'] for b in uses if b['name'] == 'mcp__chauffeur__chauffeur_discover')
        block = next(b for m in turn if m['role'] == 'user' for b in cblocks(m) if b.get('type') == 'tool_result' and b.get('tool_use_id') == discover_id)
        text = ''.join(c.get('text', '') for c in block['content']) if isinstance(block['content'], list) else block['content']
        command = json.JSONDecoder().raw_decode(text.strip())[0]['capabilities']['waitCommand']
        return tool('Bash', {'command': command, 'description': 'Wait for workers', 'run_in_background': True})
    return 0, [{'type': 'text', 'text': 'WAITING_FOR_WORKERS'}]

# ------------------------------------------------------------- Codex coordinator and worker
codex_requests = []
def ctext(item): return ' '.join(c.get('text', '') for c in item.get('content', []) if isinstance(c, dict))
def codex_decide(body, n):
    items = body.get('input', [])
    if not body.get('tools'): return 0, {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'title'}]}
    starts = [i for i, it in enumerate(items) if it.get('role') == 'user' and ctext(it).strip().startswith(MARKERS)]
    prompt = ctext(items[starts[-1]]).strip() if starts else ''
    turn = items[starts[-1] + 1:] if starts else []
    last = items[-1] if items else {}
    calls = [i.get('name') for i in turn if i.get('type') == 'function_call']
    def mcp(name, value):
        if last.get('type') == 'tool_search_output':
            with lock: issued.append(('codex', name, prompt))
            return 0, {'type': 'function_call', 'call_id': f'c{n}', 'namespace': 'mcp__chauffeur', 'name': name, 'arguments': json.dumps(value)}
        return 0, {'type': 'tool_search_call', 'call_id': f't{n}', 'execution': 'client', 'status': 'completed', 'arguments': {'query': name.replace('_', ' ')}}
    def say(t): return 0, {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': t}]}
    if prompt.startswith('Chauffeur:'):
        return mcp('chauffeur_inbox', {}) if 'chauffeur_inbox' not in calls else say('RESULT_HANDLED')
    if prompt.startswith('DELEGATE'):
        _, preset, folder, key = prompt.split(' ')
        return mcp('chauffeur_delegate', {'task': 'WORKER report', 'presetID': preset, 'folderID': folder, 'shareCheckout': True, 'retryKey': key}) if 'chauffeur_delegate' not in calls else say('DELEGATED')
    if prompt.startswith('WORKER'):
        if 'exec_command' not in calls:
            with lock: issued.append(('codex', 'exec_command', prompt))
            return 0, {'type': 'function_call', 'call_id': f'c{n}', 'name': 'exec_command', 'arguments': json.dumps({'cmd': 'sleep 8', 'max_output_tokens': 20})}
        if 'chauffeur_discover' not in calls: return mcp('chauffeur_discover', {})
        if 'chauffeur_report_result' not in calls:
            found = json.dumps(turn)
            delegation = re.search(r'delegationID\\*"\s*:\s*\\*"([0-9A-Fa-f-]{36})', found).group(1)
            turn_id = re.search(r'currentTurnID\\*"\s*:\s*\\*"([0-9A-Fa-f-]{36})', found)
            value = {'delegationID': delegation, 'result': 'worker-result-' + delegation[:8], 'retryKey': 'result'}
            if turn_id: value['turnID'] = turn_id.group(1)
            return mcp('chauffeur_report_result', value)
    return say('done')
class CodexMock(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{"data":[]}')
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.headers.get('Content-Encoding') == 'zstd': raw = subprocess.run(['zstd', '-d', '--stdout'], input=raw, capture_output=True).stdout
        body = json.loads(raw)
        with lock: codex_requests.append((time.monotonic(), body)); n = len(codex_requests)
        delay, item = codex_decide(body, n); item.setdefault('id', f'i{n}'); item.setdefault('status', 'completed')
        time.sleep(delay)
        ev = [{'type': 'response.created', 'response': {'id': f'r{n}', 'object': 'response', 'status': 'in_progress', 'output': []}},
              {'type': 'response.output_item.added', 'output_index': 0, 'item': item}, {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
              {'type': 'response.completed', 'response': {'id': f'r{n}', 'object': 'response', 'status': 'completed', 'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
        out = ''.join(f'event: {e["type"]}\ndata: {json.dumps(e)}\n\n' for e in ev).encode()
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)

def wait(probe, timeout=60, label='condition'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value: return value
        except (OSError, ValueError, AssertionError, KeyError, StopIteration, IndexError): pass
        time.sleep(0.2)
    raise AssertionError('Timed out: ' + label)
def exact(s, n):
    b = bytearray()
    while len(b) < n:
        v = s.recv(n - len(b)); assert v, 'connection closed'; b.extend(v)
    return b

claude_server, claude_requests = claude_mock_api.serve(claude_decide)
codex_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), CodexMock)
threading.Thread(target=codex_server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='chw-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    home = root / 'home'; home.mkdir()
    checkout = root / 'checkout'; checkout.mkdir()
    subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
    subprocess.run(['git', '-C', str(checkout), '-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'init'], check=True)
    claude_profile, codex_profile = root / 'claude-profile', root / 'codex-profile'
    # Only Chauffeur's tools and reading files are pre-approved here; the waiter
    # command itself must be allowed by Chauffeur's launch settings.
    claude_mock_api.profile(claude_profile, claude_server.server_port, allow=['mcp__chauffeur', 'Read'], trusted=[checkout])
    codex_profile.mkdir()
    (codex_profile / 'config.toml').write_text(f'''model = "gpt-5.4"
model_provider = "mock"
[model_providers.mock]
name = "Local mock"
base_url = "http://127.0.0.1:{codex_server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
[features]
enable_request_compression = false
shell_snapshot = false
[projects.{json.dumps(str(checkout))}]
trust_level = "trusted"
[notice]
hide_full_access_warning = true
[notice.model_migrations]
"gpt-5.4" = "gpt-6-sol"
''' + ''.join(f'[mcp_servers.chauffeur.tools.{name}]\napproval_mode = "approve"\n' for name in ['chauffeur_inbox', 'chauffeur_delegate', 'chauffeur_discover', 'chauffeur_report_result']))
    log = open(artifacts / 'runtime.private.log', 'w')
    runtime = subprocess.Popen([str(options.runtime.resolve(strict=True)), '--data-dir', str(root)], stdout=log, stderr=log,
                               env={**os.environ, 'HOME': str(home), 'SHELL': '/bin/false'})
    def call(method, params=None):
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(30); s.connect(str(root / 'runtime/runtime.sock'))
            b = json.dumps({'id': uid(), 'version': 1, 'method': method, 'params': params or {}}).encode()
            s.sendall(struct.pack('!I', len(b)) + b)
            d = json.loads(exact(s, struct.unpack('!I', exact(s, 4))[0]))
            assert not d.get('error'), d.get('error')
            return d.get('result')
    def tmux_run(*args): return subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), *args], capture_output=True, text=True)
    def screen(s): return tmux_run('capture-pane', '-p', '-t', s['id']).stdout
    def keys(s, value): tmux_run('send-keys', '-t', s['id'], '-l', '--', value); time.sleep(0.6); tmux_run('send-keys', '-t', s['id'], 'Enter')
    def snapshot(): return call('snapshot')
    def current(s): return next(v for v in snapshot()['sessions'] if v['id'] == s['id'])
    def ready(s):
        def probe():
            view = screen(s)
            for fatal in ['Hooks need review', 'Trust this folder?', 'Quick safety check', 'Do you want to proceed?', 'Detected a custom API key']:
                if fatal in view: raise Fatal(f'{s["title"]}: unexpected prompt: {fatal}')
            return 'Ask Codex to do anything' in view or ('? for shortcuts' in view and '❯' in view)
        wait(probe, label='prompt ' + s['title'])
    def result_message(prefix): return next((m for m in snapshot()['messages'] if m['body'].startswith('worker-result') and m.get('delegationID')), None)
    sessions, results = [], {}
    try:
        wait(lambda: call('status').get('mcpEndpoint'), label='runtime')
        now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        set_id, claude_preset, codex_preset, project_id, folder_id, group_id = [uid() for _ in range(6)]
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Wait fixture', 'agentSelection': 'custom', 'configurationDirectories': {'claude': str(claude_profile), 'codex': str(codex_profile)}, 'revision': 1, 'archived': False}})
        call('savePreset', {'record': {'id': claude_preset, 'setID': set_id, 'name': 'Claude mock', 'kind': 'claude', 'executable': options.claude, 'configurationDirectory': str(claude_profile), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('savePreset', {'record': {'id': codex_preset, 'setID': set_id, 'name': 'Codex mock', 'kind': 'codex', 'executable': options.codex, 'configurationDirectory': str(codex_profile), 'arguments': ['-a', 'never', '-s', 'danger-full-access'], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Wait fixture', 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': 'Checkout', 'selectedPath': str(checkout), 'canonicalPath': str(checkout), 'availability': 'available', 'registered': True}], 'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        def launch(title, preset):
            s = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset, 'folderID': folder_id, 'additionalFolderIDs': [], 'title': title, 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()})
            if s['launch'].get('configurationUsesDefault'): raise Fatal(title + ' is not using its mock profile')
            sessions.append(s); ready(s); return s

        # Claude coordinator with a background waiter.
        c = launch('Claude coordinator', claude_preset)
        keys(c, f'DELEGATE {codex_preset} {folder_id}')
        wait(lambda: any(i[1] == 'Bash' for i in list(issued)), label='Claude started the waiter')
        wait(lambda: current(c).get('waiting') == 'workers' and current(c)['state'] == 'turnFinished', label='Claude waiting for workers')
        assert not current(c)['unread'], 'waiting is not unread work'
        idle_requests = len([r for r in claude_requests if r.get('tools')])
        worker = wait(lambda: next(s for s in snapshot()['sessions'] if s.get('parentID') == c['id']), label='worker launched')
        sessions.append(worker)
        wait(lambda: result_message('worker-result'), timeout=90, label='worker result')
        wait(lambda: any(i[1] == 'woke-read' for i in list(issued)), timeout=40, label='Claude woke and read the waiter output')
        read = next(i[2] for i in issued if i[1] == 'woke-read')
        assert 'worker-result-' in read and 'already acknowledged' in read, read[:400]
        wakes = [r for r in claude_requests[idle_requests:] if r.get('tools') and 'task-notification' in json.dumps(r['messages'][-1:])]
        between = [r for r in claude_requests[idle_requests:] if r.get('tools') and 'task-notification' not in json.dumps(r) ]
        assert len(wakes) == 1 and not between, (len(wakes), len(between))
        wait(lambda: current(c).get('waiting') is None, label='waiting cleared')
        results['claude'] = 'waiter pre-approved; waiting for workers; zero model requests while waiting; one wake with the printed result'

        # Codex coordinator with the result wake.
        x = launch('Codex coordinator', codex_preset)
        keys(x, f'DELEGATE {codex_preset} {folder_id} codex-worker')
        wait(lambda: any(i[1] == 'chauffeur_delegate' and i[2].endswith('codex-worker') for i in list(issued)), label='Codex delegated')
        wait(lambda: current(x)['state'] == 'turnFinished', label='Codex coordinator idle')
        worker2 = wait(lambda: next(s for s in snapshot()['sessions'] if s.get('parentID') == x['id']), label='second worker launched')
        sessions.append(worker2)
        wait(lambda: any(i[1] == 'exec_command' for i in list(issued)[-10:]) and current(worker2)['state'] == 'running', label='worker running')
        results['codexStatus'] = 'long worker turn shows running'
        idle = len(codex_requests)
        wait(lambda: any(i[1] == 'chauffeur_inbox' and i[2].startswith('Chauffeur:') for i in list(issued)), timeout=90, label='result wake read inbox')
        wake_prompts = [ctext(it) for _, b in codex_requests[idle:] for it in b.get('input', [])[-2:] if it.get('role') == 'user' and ctext(it).startswith('Chauffeur:')]
        assert wake_prompts and all('1 new worker result' in p for p in wake_prompts), wake_prompts
        typed = sum(screen(x).count(line) for line in ['Chauffeur: 1 new worker result'])
        assert typed == 1, typed
        results['codex'] = 'one typed result wake; coordinator read its inbox'
        results['result'] = 'pass'
        (artifacts / 'summary.json').write_text(json.dumps(results, indent=2))
        print(json.dumps(results, indent=2))
    except BaseException:
        for s in sessions: (artifacts / f'terminal-{s["title"].replace(" ", "-")}.private.txt').write_text(screen(s))
        (artifacts / 'claude-requests.private.json').write_text(json.dumps(claude_requests, indent=1))
        (artifacts / 'codex-requests.private.json').write_text(json.dumps([b for _, b in codex_requests], indent=1))
        try: (artifacts / 'snapshot.private.json').write_text(json.dumps(snapshot(), indent=2))
        except Exception: pass
        print(json.dumps(results, indent=2))
        raise
    finally:
        try:
            for s in snapshot()['sessions']:
                if s['state'] not in ('exited', 'failed', 'interrupted'): call('stop', {'sessionID': s['id'], 'force': True})
        except Exception: pass
        runtime.terminate()
        try: runtime.wait(timeout=5)
        except subprocess.TimeoutExpired: runtime.kill()
        tmux_run('kill-server'); claude_server.shutdown(); codex_server.shutdown(); log.close()
