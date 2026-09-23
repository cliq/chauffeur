#!/usr/bin/env python3
"""Cross-provider inbox reminders through the real runtime, the real Claude Code
TUI and the real Codex TUI, with scripted local mock providers (no accounts, no
paid inference). Both mocks run in this process; each session's throwaway profile
points its CLI at them.

Checks:
- Codex → Claude and Claude → Codex mail while the recipient is busy arrives as one
  PostToolUse reminder, and the recipient reads its inbox;
- mail arriving while Claude writes its final answer continues the turn exactly once;
- `/clear` in Claude during an active delegation: Chauffeur follows the new
  conversation, the worker's result still routes to the coordinator, and the next
  prompt mentions "1 worker result";
- `/resume <id>` in Claude moves back, and Chauffeur's Resume reopens it;
- a runtime restart mid-turn neither duplicates nor loses mail;
- ~/.codex and ~/.claude/settings.json are unchanged.

  swift build && Prototypes/cross_provider_inbox_smoke.py
"""
import argparse, hashlib, http.server, json, os, re, shutil, socket, struct, subprocess, sys, tempfile, threading, time, uuid
from pathlib import Path

os.umask(0o077)
repo = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repo / 'Prototypes/inbox_hooks'))
import claude_mock_api

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--codex', default=shutil.which('codex'))
parser.add_argument('--claude', default=shutil.which('claude'))
parser.add_argument('--runtime', type=Path, default=repo / '.build/debug/ChauffeurRuntime')
parser.add_argument('--artifacts', type=Path, default=repo / '.local/cross-provider-inbox-artifacts')
options = parser.parse_args()
tmux = shutil.which('tmux')
assert options.codex and options.claude and tmux, 'Install Codex, Claude Code and tmux first'
artifacts = options.artifacts.resolve(); artifacts.mkdir(parents=True, exist_ok=True)
HINT = 'Chauffeur: '
MARKERS = ('BUSY', 'QUICK', 'SEND', 'HELLO', 'DELEGATE', 'WORKER')

def uid(): return str(uuid.uuid4()).upper()
def same(a, b): return bool(a and b) and uuid.UUID(a) == uuid.UUID(b)
def digests():
    files = [Path.home() / '.codex/config.toml', Path.home() / '.codex/hooks.json', Path.home() / '.claude/settings.json']
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.exists()}
class Fatal(Exception): pass
lock = threading.Lock()
issued = []  # (provider, conversation, tool or 'text', prompt)

# ------------------------------------------------------------ Claude mock
def claude_prompt(messages):
    for index in range(len(messages) - 1, -1, -1):
        message = messages[index]
        if message['role'] != 'user': continue
        blocks = message['content'] if isinstance(message['content'], list) else [{'type': 'text', 'text': message['content']}]
        for block in blocks:
            if block.get('type') == 'text' and block['text'].strip().startswith(MARKERS):
                return index, block['text'].strip()
    return None, ''
def claude_turn(body):
    index, prompt = claude_prompt(body.get('messages', []))
    return prompt, ([] if index is None else body['messages'][index:])
def claude_decide(body):
    tools = {t.get('name') for t in body.get('tools', [])}
    prompt, turn = claude_turn(body)
    if not tools or not prompt:
        return 0, [{'type': 'text', 'text': 'Mock title'}]
    used = [b.get('name') for m in turn if m['role'] == 'assistant' and isinstance(m['content'], list) for b in m['content'] if b.get('type') == 'tool_use']
    hinted = HINT in json.dumps(turn[1:]) or HINT in json.dumps([b for b in (turn[0]['content'] if isinstance(turn[0]['content'], list) else []) if not b.get('text', '').strip().startswith(MARKERS)])
    session = body.get('metadata', {}).get('user_id', '')
    def tool(name, value):
        with lock: issued.append(('claude', session, name, prompt))
        return 0, [{'type': 'tool_use', 'name': name, 'input': value}]
    if hinted and 'mcp__chauffeur__chauffeur_inbox' not in used:
        return tool('mcp__chauffeur__chauffeur_inbox', {})
    if prompt.startswith('SEND ') and 'mcp__chauffeur__chauffeur_send_message' not in used:
        _, recipient, text = prompt.split(' ', 2)
        return tool('mcp__chauffeur__chauffeur_send_message', {'recipientID': recipient, 'body': text, 'retryKey': text})
    if prompt.startswith('DELEGATE ') and 'mcp__chauffeur__chauffeur_delegate' not in used:
        _, preset, folder = prompt.split(' ')
        return tool('mcp__chauffeur__chauffeur_delegate', {'task': 'WORKER report', 'presetID': preset, 'folderID': folder, 'shareCheckout': True, 'retryKey': 'worker-1'})
    if prompt.startswith('BUSY') and 'Bash' not in used:
        return tool('Bash', {'command': 'sleep 7', 'description': 'Wait'})
    if prompt.startswith('QUICK') and not any(m['role'] == 'assistant' for m in turn):
        return 7, [{'type': 'text', 'text': 'QUICK_REPLY'}]
    return 0, [{'type': 'text', 'text': 'DONE ' + prompt.split(' ')[0]}]

# ------------------------------------------------------------- Codex mock
codex_requests = []
def ctext(item): return ' '.join(c.get('text', '') for c in item.get('content', []) if isinstance(c, dict))
def cprompt(item): return item.get('role') == 'user' and ctext(item).strip().startswith(MARKERS)
def codex_decide(body, n):
    items = body.get('input', [])
    if not body.get('tools'): return 0, {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'Mock title'}]}
    starts = [i for i, item in enumerate(items) if cprompt(item)]
    prompt = ctext(items[starts[-1]]).strip() if starts else ''
    turn = items[starts[-1] + 1:] if starts else []
    last = items[-1] if items else {}
    calls = [i.get('name') for i in turn if i.get('type') == 'function_call']
    hinted = any(HINT in ctext(i) for i in turn if i.get('role') in ('developer', 'user'))
    thread = body.get('prompt_cache_key')
    def mcp(name, value):
        if last.get('type') == 'tool_search_output':
            with lock: issued.append(('codex', thread, name, prompt))
            return 0, {'type': 'function_call', 'call_id': f'call_{n}', 'namespace': 'mcp__chauffeur', 'name': name, 'arguments': json.dumps(value)}
        return 0, {'type': 'tool_search_call', 'call_id': f'ts_{n}', 'execution': 'client', 'status': 'completed', 'arguments': {'query': name.replace('_', ' ')}}
    if hinted and 'chauffeur_inbox' not in calls: return mcp('chauffeur_inbox', {})
    if prompt.startswith('SEND ') and 'chauffeur_send_message' not in calls:
        _, recipient, text = prompt.split(' ', 2)
        return mcp('chauffeur_send_message', {'recipientID': recipient, 'body': text, 'retryKey': text})
    if prompt.startswith(('BUSY', 'WORKER')) and 'exec_command' not in calls:
        with lock: issued.append(('codex', thread, 'exec_command', prompt))
        return 0, {'type': 'function_call', 'call_id': f'call_{n}', 'name': 'exec_command', 'arguments': json.dumps({'cmd': 'sleep 7', 'max_output_tokens': 20})}
    if prompt.startswith('WORKER') and 'chauffeur_discover' not in calls: return mcp('chauffeur_discover', {})
    if prompt.startswith('WORKER') and 'chauffeur_report_result' not in calls:
        found = json.dumps(turn)
        delegation = re.search(r'delegationID\\*"\s*:\s*\\*"([0-9A-Fa-f-]{36})', found).group(1)
        turn_id = re.search(r'currentTurnID\\*"\s*:\s*\\*"([0-9A-Fa-f-]{36})', found)
        value = {'delegationID': delegation, 'result': 'worker-result', 'retryKey': 'worker-result'}
        if turn_id: value['turnID'] = turn_id.group(1)
        return mcp('chauffeur_report_result', value)
    return 0, {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'DONE ' + prompt.split(' ')[0]}]}
class CodexMock(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'{"data":[]}')
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.headers.get('Content-Encoding') == 'zstd': raw = subprocess.run(['zstd', '-d', '--stdout'], input=raw, capture_output=True).stdout
        body = json.loads(raw)
        with lock: codex_requests.append(body); n = len(codex_requests)
        delay, item = codex_decide(body, n); item.setdefault('id', f'item_{n}'); item.setdefault('status', 'completed')
        time.sleep(delay)
        events = [{'type': 'response.created', 'response': {'id': f'r{n}', 'object': 'response', 'status': 'in_progress', 'output': []}},
                  {'type': 'response.output_item.added', 'output_index': 0, 'item': item}, {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
                  {'type': 'response.completed', 'response': {'id': f'r{n}', 'object': 'response', 'status': 'completed', 'output': [item], 'usage': {'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2}}}]
        out = ''.join(f'event: {e["type"]}\ndata: {json.dumps(e)}\n\n' for e in events).encode()
        self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)

# ---------------------------------------------------------------- helpers
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

before = digests()
claude_server, claude_requests = claude_mock_api.serve(claude_decide)
codex_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), CodexMock)
threading.Thread(target=codex_server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='chc-', dir='/tmp') as directory:
    root = Path(directory).resolve()
    checkout = root / 'checkout'; checkout.mkdir()
    subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
    subprocess.run(['git', '-C', str(checkout), '-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'init'], check=True)
    claude_profile, codex_profile = root / 'claude-profile', root / 'codex-profile'
    claude_mock_api.profile(claude_profile, claude_server.server_port, allow=['mcp__chauffeur', 'Bash(sleep:*)'], trusted=[checkout])
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
''' + ''.join(f'[mcp_servers.chauffeur.tools.{name}]\napproval_mode = "approve"\n' for name in ['chauffeur_inbox', 'chauffeur_send_message', 'chauffeur_discover', 'chauffeur_report_result']))
    log = open(artifacts / 'runtime.private.log', 'w')
    def start_runtime(): return subprocess.Popen([str(options.runtime.resolve(strict=True)), '--data-dir', str(root)], stdout=log, stderr=log)
    runtime = start_runtime()
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
    def messages(body): return [m for m in snapshot()['messages'] if m['body'] == body]
    def ready(s):
        def probe():
            view = screen(s)
            for fatal in ['Hooks need review', 'Trust this folder?', 'Do you trust the files', 'Quick safety check', 'Detected a custom API key', 'Select login method']:
                if fatal in view: raise Fatal(f'{s["title"]}: unexpected prompt: {fatal}')
            if 'GPT-5.4 is no longer available' in view: tmux_run('send-keys', '-t', s['id'], '2'); tmux_run('send-keys', '-t', s['id'], 'Enter'); return False
            return 'Ask Codex to do anything' in view or ('? for shortcuts' in view and '❯' in view)
        wait(probe, label='prompt ' + s['title'])
    def args_of(s): return subprocess.check_output(['/bin/ps', '-o', 'args=', '-p', str(current(s)['processID'])], text=True)
    def issued_for(provider, name, prompt):
        with lock: return [i for i in issued if i[0] == provider and i[2] == name and i[3] == prompt]
    def claude_turn_requests(prompt):
        return [r for r in list(claude_requests) if r.get('tools') and claude_turn(r)[0] == prompt]
    def claude_saw(prompt, needle):
        """Occurrences of needle in the latest request of that Claude turn."""
        requests = claude_turn_requests(prompt)
        return json.dumps(claude_turn(requests[-1])[1]).count(needle) if requests else 0

    sessions, results = [], {}
    try:
        wait(lambda: call('status').get('mcpEndpoint'), label='runtime')
        now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        set_id, claude_preset, codex_preset, project_id, folder_id, group_id = [uid() for _ in range(6)]
        call('savePresetSet', {'record': {'id': set_id, 'name': 'Cross fixture', 'agentSelection': 'custom', 'configurationDirectories': {'claude': str(claude_profile), 'codex': str(codex_profile)}, 'revision': 1, 'archived': False}})
        call('savePreset', {'record': {'id': claude_preset, 'setID': set_id, 'name': 'Claude mock', 'kind': 'claude', 'executable': options.claude, 'configurationDirectory': str(claude_profile), 'arguments': [], 'integration': 'unverified', 'archived': False}})
        call('savePreset', {'record': {'id': codex_preset, 'setID': set_id, 'name': 'Codex mock', 'kind': 'codex', 'executable': options.codex, 'configurationDirectory': str(codex_profile), 'arguments': ['-a', 'never', '-s', 'danger-full-access'], 'integration': 'unverified', 'archived': False}})
        call('saveProject', {'record': {'id': project_id, 'name': 'Cross fixture', 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': 'Checkout', 'selectedPath': str(checkout), 'canonicalPath': str(checkout), 'availability': 'available', 'registered': True}], 'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
        for title, preset in [('Claude C', claude_preset), ('Codex X', codex_preset)]:
            sessions.append(call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset, 'folderID': folder_id, 'additionalFolderIDs': [], 'title': title, 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()}))
        c, x = sessions
        # Never type into a session that could reach a real provider account.
        for s, profile in [(c, claude_profile), (x, codex_profile)]:
            if s['launch']['configurationPath'] != str(profile) or s['launch'].get('configurationUsesDefault'): raise Fatal(s['title'] + ' is not using its mock profile')
        for s in sessions: ready(s); assert current(s).get('inboxReminders') is True, s['title']
        original = current(c)['nativeConversationID']

        # Codex -> busy Claude.
        keys(c, 'BUSY one'); wait(lambda: issued_for('claude', 'Bash', 'BUSY one'), label='Claude busy'); time.sleep(1)
        keys(x, f'SEND {c["id"]} codex-to-claude')
        wait(lambda: messages('codex-to-claude'), label='Codex sent')
        wait(lambda: issued_for('claude', 'mcp__chauffeur__chauffeur_inbox', 'BUSY one'), timeout=40, label='Claude read inbox')
        assert claude_saw('BUSY one', 'Chauffeur: 1 new inbox message.') == 1, 'one PostToolUse reminder'
        assert 'codex-to-claude' not in json.dumps([r['messages'][-1] for r in claude_turn_requests('BUSY one')][:1])
        results['codexToBusyClaude'] = 'one PostToolUse reminder, then chauffeur_inbox'

        # Claude -> busy Codex.
        wait(lambda: current(c)['state'] == 'turnFinished', label='Claude idle')
        keys(x, 'BUSY one'); wait(lambda: issued_for('codex', 'exec_command', 'BUSY one'), label='Codex busy'); time.sleep(1)
        keys(c, f'SEND {x["id"]} claude-to-codex')
        wait(lambda: messages('claude-to-codex'), label='Claude sent')
        wait(lambda: issued_for('codex', 'chauffeur_inbox', 'BUSY one'), timeout=40, label='Codex read inbox')
        results['claudeToBusyCodex'] = 'PostToolUse reminder, then chauffeur_inbox'

        # Mail during Claude's final answer: one Stop continuation.
        wait(lambda: current(c)['state'] == 'turnFinished', label='Claude idle 2')
        keys(c, 'QUICK one'); wait(lambda: claude_turn_requests('QUICK one'), label='Claude answering')
        wait(lambda: current(x)['state'] == 'turnFinished', label='Codex idle')
        keys(x, f'SEND {c["id"]} late-to-claude')
        wait(lambda: messages('late-to-claude'), label='late mail')
        wait(lambda: issued_for('claude', 'mcp__chauffeur__chauffeur_inbox', 'QUICK one'), timeout=40, label='Stop continuation')
        wait(lambda: current(c)['state'] == 'turnFinished', label='Claude finished')
        time.sleep(2)
        assert claude_saw('QUICK one', 'Stop hook feedback') == 1, claude_saw('QUICK one', 'Stop hook feedback')
        results['claudeStop'] = 'exactly one Stop continuation'

        # /clear during an active delegation still routes the worker result.
        keys(c, f'DELEGATE {codex_preset} {folder_id}')
        wait(lambda: issued_for('claude', 'mcp__chauffeur__chauffeur_delegate', f'DELEGATE {codex_preset} {folder_id}'), label='delegated')
        wait(lambda: current(c)['state'] == 'turnFinished', label='coordinator idle')
        keys(c, '/clear')
        cleared = wait(lambda: (lambda v: v if not same(v, original) else None)(current(c)['nativeConversationID']), label='/clear adopted')
        worker = wait(lambda: next(s for s in snapshot()['sessions'] if s.get('parentID') == c['id']), label='worker launched')
        sessions.append(worker)
        result = wait(lambda: next(m for m in snapshot()['messages'] if m.get('delegationID') and m['body'] == 'worker-result'), timeout=90, label='worker result')
        assert result['recipientID'] == c['id']
        ready(c); keys(c, 'HELLO after clear')
        wait(lambda: issued_for('claude', 'mcp__chauffeur__chauffeur_inbox', 'HELLO after clear'), timeout=40, label='coordinator read result')
        assert claude_saw('HELLO after clear', '(1 worker result)') >= 1
        results['clearDuringDelegation'] = 'new conversation adopted; worker result routed and hinted'

        # /resume moves back; Chauffeur Resume reopens the active conversation.
        wait(lambda: current(c)['state'] == 'turnFinished', label='coordinator idle 2')
        keys(c, f'/resume {original}')
        wait(lambda: same(current(c)['nativeConversationID'], original), label='/resume adopted')
        call('stop', {'sessionID': c['id'], 'force': True})
        resumed = call('resume', {'sessionID': c['id']})
        assert same(resumed['nativeConversationID'], original) and original.lower() in args_of(c).lower()
        ready(c)
        results['resume'] = 'Claude /clear and /resume followed; Resume reopens the active conversation'

        # Runtime restart mid-turn: no duplicate and no loss.
        keys(c, 'BUSY two'); wait(lambda: issued_for('claude', 'Bash', 'BUSY two'), label='Claude busy 2')
        runtime.kill(); runtime.wait(timeout=5)
        runtime = start_runtime(); wait(lambda: call('status').get('mcpEndpoint'), label='runtime restart')
        wait(lambda: current(x)['state'] in ('turnFinished', 'activityUnknown'), label='Codex idle 2')
        keys(x, f'SEND {c["id"]} after-restart')
        wait(lambda: messages('after-restart'), label='mail after restart')
        wait(lambda: issued_for('claude', 'mcp__chauffeur__chauffeur_inbox', 'BUSY two'), timeout=40, label='Claude read after restart')
        assert len(messages('after-restart')) == 1 and claude_saw('BUSY two', 'Chauffeur: 1 new inbox message.') == 1
        results['runtimeRestart'] = 'one message, one reminder'

        for s in (c, x):
            view = screen(s); (artifacts / f'terminal-{s["title"].replace(" ", "-")}.private.txt').write_text(view)
            # Claude labels the intended Stop continuation "Stop hook error: <reason>"; anything else is a failure.
            unexpected = [line for line in view.splitlines() if 'hook error' in line.lower() and HINT not in line]
            assert not unexpected and 'different native conversation' not in view, (s['title'], unexpected)
        results['hookErrors'] = 'none besides the labelled Stop continuation'
        assert digests() == before, 'user provider configuration changed'
        results['userConfiguration'] = 'unchanged'
        results['versions'] = {s['title']: current(s)['launch']['executableVersion'] for s in (c, x)}
        results['result'] = 'pass'
        (artifacts / 'summary.json').write_text(json.dumps(results, indent=2))
        print(json.dumps(results, indent=2))
    except BaseException:
        for s in sessions: (artifacts / f'terminal-{s["title"].replace(" ", "-")}.private.txt').write_text(screen(s))
        (artifacts / 'claude-requests.private.json').write_text(json.dumps(claude_requests, indent=1))
        (artifacts / 'codex-requests.private.json').write_text(json.dumps(codex_requests, indent=1))
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
