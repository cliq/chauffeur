#!/usr/bin/env python3
"""OpenCode sessions end to end through the real runtime, the real OpenCode TUI and
the real Claude Code TUI, with scripted local mock providers (no accounts, no paid
inference). OpenCode talks to an OpenAI-compatible Chat Completions mock
(`inbox_hooks/openai_mock_api.py`) configured in an isolated
`$XDG_CONFIG_HOME/opencode/opencode.json`; HOME and every XDG directory are
throwaway, and the data root contains a space ("Application Support") so the
plugin's percent-encoded file:// URL is exercised.

Checks:
- Launch: the plugin loads, `session-start` adopts the `ses_…` ID, and the status
  goes Running → Turn finished.
- Attention: a bash command under an "ask" rule and a question prompt show Needs attention in an
  interactive session; answering it returns to Running. With --auto, no attention.
- Mail: mail arriving mid-turn is appended once to the next tool output
  (PostToolUse); mail arriving while the model writes its final answer continues
  the turn once through `promptAsync`.
- Coordinator: an OpenCode coordinator delegates to an OpenCode worker and a Claude
  worker; discovery reports `pluginWait`; it ends its turn and the model gets no
  requests while waiting; the plugin's waiter wakes it once per result.
- Follow-up: `chauffeur_follow_up` to the idle OpenCode worker is typed in through
  the composer rule. Real screens (first turn, idle, draft, busy) are captured and
  classified with the same rule as `OpenCodeProvider.composerReadiness(screen:)`.
- Resume: stop and resume uses `-s <ses_…>` and keeps the conversation.
- /new: a new conversation started in the TUI takes over once prompted; mail continues
  it, and a later resume reopens it rather than the first one.
- Chauffeur lists its MCP tools to OpenCode without the `chauffeur_` prefix, so
  OpenCode shows (and the mock calls) the names the skills use, e.g. `chauffeur_inbox`.
- `chauffeur_inbox` waits are capped at 240 s for OpenCode (skip with --quick).
- The snapshot and the remote inventory mapping name the session kind `opencode`.

  swift build && Prototypes/opencode_smoke.py
"""
import argparse, json, os, re, shutil, socket, struct, subprocess, sys, tempfile, threading, time, urllib.request, uuid
from pathlib import Path

os.umask(0o077)
repo = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repo / 'Prototypes/inbox_hooks'))
import claude_mock_api, openai_mock_api

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--opencode', default=shutil.which('opencode'))
parser.add_argument('--claude', default=shutil.which('claude'))
parser.add_argument('--runtime', type=Path, default=repo / '.build/debug/ChauffeurRuntime')
parser.add_argument('--artifacts', type=Path, default=repo / '.local/opencode-smoke')
parser.add_argument('--quick', action='store_true', help='skip the 240 s inbox wait cap check')
parser.add_argument('--keep', action='store_true', help='keep the temporary root for inspection')
options = parser.parse_args()
tmux = shutil.which('tmux')
assert options.opencode and options.claude and tmux, 'Install OpenCode, Claude Code and tmux first'
artifacts = options.artifacts.resolve(); artifacts.mkdir(parents=True, exist_ok=True)
for old in artifacts.glob('*'):
    if old.is_file(): old.unlink()
MARKERS = ('FRESH', 'REOPENED', 'ASK', 'QUESTION', 'AUTO', 'BUSY', 'QUICK', 'SEND', 'DELEGATE', 'WORKER', 'FOLLOWUP', 'RESUMED', 'Chauffeur:')
HINT = 'Chauffeur: '

def uid(): return str(uuid.uuid4()).upper()
class Fatal(Exception): pass
lock = threading.Lock()
issued = []  # (provider, tool or 'text', prompt, extra)
def note(provider, name, prompt, extra=None):
    with lock: issued.append((provider, name, prompt, extra))
def issued_for(provider, name, prefix=''):
    with lock: return [i for i in issued if i[0] == provider and i[1] == name and i[2].startswith(prefix)]

# ------------------------------------------------------------ OpenCode mock (Chat Completions)
text_of = openai_mock_api.text_of
def oc_turn(messages):
    """(prompt, turn messages after it, all messages) for the latest marked user prompt."""
    for index in range(len(messages) - 1, -1, -1):
        m = messages[index]
        if m['role'] == 'user' and text_of(m).strip().startswith(MARKERS):
            return text_of(m).strip(), messages[index + 1:]
    return '', []
# OpenCode names MCP tools `<server>_<tool>`; Chauffeur lists `inbox` etc. to it, so OpenCode shows `chauffeur_inbox`.
def oc_wire(name): return name
def oc_name(name): return name
def oc_calls(turn): return [oc_name(c['function']['name']) for m in turn if m['role'] == 'assistant' for c in (m.get('tool_calls') or [])]
def oc_results(turn, name):
    ids = {c['id'] for m in turn if m['role'] == 'assistant' for c in (m.get('tool_calls') or []) if oc_name(c['function']['name']) == name}
    return [text_of(m) for m in turn if m['role'] == 'tool' and m.get('tool_call_id') in ids]
def conversation(messages): return '\n'.join(text_of(m) for m in messages if m['role'] == 'user')
def oc_decide(body):
    messages = body.get('messages', [])
    if not body.get('tools'): return 0, [{'type': 'text', 'text': 'Mock title'}]
    prompt, turn = oc_turn(messages)
    calls = oc_calls(turn)
    everything = json.dumps(turn)
    def tool(name, value, delay=0):
        note('opencode', name, prompt, value)
        return delay, [{'type': 'tool', 'name': oc_wire(name), 'input': value}]
    def say(t, delay=0):
        note('opencode', 'text', prompt, t)
        return delay, [{'type': 'text', 'text': t}]
    hinted = HINT in json.dumps([m for m in turn if m['role'] == 'tool'])
    if 'invalid' in calls: return say('UNAVAILABLE_TOOL')  # never loop on a tool OpenCode rejected
    if prompt.startswith(('ASK', 'AUTO')):
        name = prompt.split(' ')[0].lower() + '-' + prompt.split(' ')[1]
        if 'bash' not in calls: return tool('bash', {'command': f'touch {name}.txt', 'description': 'Create a marker file'})
        return say(prompt.split(' ')[0] + '_DONE')
    if prompt.startswith('QUESTION'):
        if 'question' not in calls:
            return tool('question', {'questions': [{'question': 'Which marker should I use?', 'header': 'Marker', 'options': [
                {'label': 'Alpha', 'description': 'The first marker'}, {'label': 'Beta', 'description': 'The second marker'}]}]})
        return say('QUESTION_DONE ' + ('answered' if 'Alpha' in json.dumps(oc_results(turn, 'question')) else 'unanswered'))
    if prompt.startswith('BUSY'):
        if 'bash' not in calls: return tool('bash', {'command': 'sleep 7', 'description': 'Wait a little'})
        if hinted and 'chauffeur_inbox' not in calls: return tool('chauffeur_inbox', {})
        return say('BUSY_DONE')
    if prompt.startswith('QUICK'):
        return say('QUICK_REPLY', delay=8)
    if prompt.startswith('SEND'):
        _, recipient, text = prompt.split(' ', 2)
        if 'chauffeur_send_message' not in calls: return tool('chauffeur_send_message', {'recipientID': recipient, 'body': text, 'retryKey': text})
        return say('SENT')
    if prompt.startswith('DELEGATE'):
        _, oc_preset, claude_preset, folder = prompt.split(' ')
        if 'chauffeur_discover' not in calls: return tool('chauffeur_discover', {})
        if calls.count('chauffeur_delegate') == 0:
            return tool('chauffeur_delegate', {'task': 'WORKER oc', 'presetID': oc_preset, 'folderID': folder, 'shareCheckout': True, 'retryKey': 'oc-worker'})
        if calls.count('chauffeur_delegate') == 1:
            return tool('chauffeur_delegate', {'task': 'WORKER claude', 'presetID': claude_preset, 'folderID': folder, 'shareCheckout': True, 'retryKey': 'claude-worker'})
        return say('WAITING_FOR_WORKERS')
    if prompt.startswith('WORKER'):
        if 'bash' not in calls: return tool('bash', {'command': 'sleep 8', 'description': 'Work'})
        if 'chauffeur_discover' not in calls: return tool('chauffeur_discover', {})
        if 'chauffeur_report_result' not in calls:
            found = oc_results(turn, 'chauffeur_discover')[-1]
            delegation = re.search(r'"delegationID"\s*:\s*"([0-9A-Fa-f-]{36})"', found).group(1)
            value = {'delegationID': delegation, 'result': 'worker-result-oc', 'retryKey': 'result'}
            turn_id = re.search(r'"currentTurnID"\s*:\s*"([0-9A-Fa-f-]{36})"', found)
            if turn_id: value['turnID'] = turn_id.group(1)
            return tool('chauffeur_report_result', value)
        return say('WORKER_DONE')
    if prompt.startswith('FOLLOWUP'):
        return say('FOLLOWUP_DONE')
    if prompt.startswith('FRESH'):
        return say('FRESH_DONE ' + ('history-kept' if 'RESUMED one' in conversation(messages) else 'history-lost'))
    if prompt.startswith('REOPENED'):
        return say('REOPENED_DONE ' + ('fresh' if 'FRESH one' in conversation(messages) and 'RESUMED one' not in conversation(messages) else 'wrong'))
    if prompt.startswith('RESUMED'):
        return say('RESUMED_DONE ' + ('history-kept' if 'ASK one' in conversation(messages) else 'history-lost'))
    if prompt.startswith('Chauffeur:'):
        coordinator = any(text_of(m).startswith('DELEGATE') for m in messages if m['role'] == 'user')
        if coordinator and 'Result from' in prompt:
            note('opencode', 'wake', prompt)
            oc = re.search(r'delegationID ([0-9A-Fa-f-]{36}), messageID [^)]*\):\nworker-result-oc', prompt)
            done = any(oc_name(c['function']['name']) == 'chauffeur_follow_up' and '"submitted"' in text_of(r)
                       for i, m in enumerate(messages) if m['role'] == 'assistant' for c in (m.get('tool_calls') or [])
                       for r in messages[i + 1:i + 2] if r['role'] == 'tool')
            if oc and not done:
                statuses = oc_results(turn, 'chauffeur_delegation_status'); attempts = oc_results(turn, 'chauffeur_follow_up')
                if len(attempts) < len(statuses):
                    turn_id = re.search(r'"currentTurnID"\s*:\s*"([0-9A-Fa-f-]{36})"', statuses[-1]).group(1)
                    return tool('chauffeur_follow_up', {'delegationID': oc.group(1), 'expectedTurnID': turn_id, 'prompt': 'FOLLOWUP check', 'retryKey': f'follow-up-{len(attempts)}'})
                if attempts and '"submitted"' in attempts[-1]: return say('FOLLOWED_UP')
                if len(attempts) < 12: return tool('chauffeur_delegation_status', {'delegationID': oc.group(1)}, delay=2 if attempts else 1)
            return say('RESULT_HANDLED')
        if 'chauffeur_inbox' not in calls: return tool('chauffeur_inbox', {})
        return say('INBOX_READ')
    return say('done')

# ------------------------------------------------------------ Claude worker mock
def cblocks(m): return m['content'] if isinstance(m['content'], list) else [{'type': 'text', 'text': m['content']}]
def claude_decide(body):
    if not body.get('tools'): return 0, [{'type': 'text', 'text': 'title'}]
    msgs = body['messages']
    start = max((i for i, m in enumerate(msgs) if m['role'] == 'user' and any(b.get('type') == 'text' and b['text'].strip().startswith('WORKER') for b in cblocks(m))), default=None)
    if start is None: return 0, [{'type': 'text', 'text': 'idle'}]
    turn = msgs[start:]
    uses = [b for m in turn if m['role'] == 'assistant' for b in cblocks(m) if b.get('type') == 'tool_use']
    names = [b['name'] for b in uses]
    def tool(name, value, delay=0):
        note('claude', name, 'WORKER claude', value)
        return delay, [{'type': 'tool_use', 'name': name, 'input': value}]
    discovered = [b for m in turn if m['role'] == 'user' for b in cblocks(m) if b.get('type') == 'tool_result' and not b.get('is_error') and 'delegationID' in json.dumps(b.get('content'))]
    # A worker starts with its task, possibly before Claude has connected to the MCP server.
    if not discovered: return tool('mcp__chauffeur__chauffeur_discover', {}, delay=2 if names else 0)
    if 'mcp__chauffeur__chauffeur_report_result' not in names:
        found = json.dumps(discovered)
        delegation = re.search(r'delegationID\\*"\s*:\s*\\*"([0-9A-Fa-f-]{36})', found).group(1)
        turn_id = re.search(r'currentTurnID\\*"\s*:\s*\\*"([0-9A-Fa-f-]{36})', found)
        value = {'delegationID': delegation, 'result': 'worker-result-claude', 'retryKey': 'result'}
        if turn_id: value['turnID'] = turn_id.group(1)
        return tool('mcp__chauffeur__chauffeur_report_result', value, delay=14)
    return 0, [{'type': 'text', 'text': 'WORKER_DONE'}]

# ------------------------------------------------------------ OpenCode composer rule (mirrors OpenCodeProvider)
def composer(lines, x, y):
    def bar(i):
        if not 0 <= i < len(lines): return None
        line = lines[i]; stripped = line.lstrip(' ')
        if not stripped.startswith('┃'): return None
        column = len(line) - len(stripped)
        return column, stripped[1:].strip()
    cursor = bar(y)
    if not cursor: return 'unrecognized'
    above = bar(y - 1)
    placeholder = cursor[1].startswith('Ask anything')
    if (cursor[1] and not placeholder) or (above and above[1] and above[0] == cursor[0]): return 'inputPending'
    below = bar(y + 1)
    if x != cursor[0] + 3 or not above or above[0] != cursor[0] or not below or below[0] != cursor[0] or below[1] or y + 3 >= len(lines): return 'unrecognized'
    status = lines[y + 2].strip()
    if not status or status == '┃' or status.startswith('╹') or not lines[y + 3].strip().startswith('╹▀'): return 'unrecognized'
    if any('esc interrupt' in l for l in lines[y + 4:]): return 'unrecognized'
    return 'ready'

# ------------------------------------------------------------ helpers
def wait(probe, timeout=60, label='condition'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value: return value
        except (OSError, ValueError, AssertionError, KeyError, StopIteration, IndexError, TypeError): pass
        time.sleep(0.2)
    raise AssertionError('Timed out: ' + label)
def exact(s, n):
    b = bytearray()
    while len(b) < n:
        v = s.recv(n - len(b)); assert v, 'connection closed'; b.extend(v)
    return b

oc_server, oc_requests = openai_mock_api.serve(oc_decide)
claude_server, claude_requests = claude_mock_api.serve(claude_decide)
base = tempfile.mkdtemp(prefix='choc-', dir='/tmp')
top = Path(base).resolve()
root = top / 'Application Support' / 'Chauffeur'; root.mkdir(parents=True)
home = top / 'home'
xdg = {'XDG_CONFIG_HOME': home / '.config', 'XDG_DATA_HOME': home / '.local/share', 'XDG_STATE_HOME': home / '.local/state', 'XDG_CACHE_HOME': home / '.cache'}
for d in xdg.values(): d.mkdir(parents=True)
oc_profile = xdg['XDG_CONFIG_HOME'] / 'opencode'; oc_profile.mkdir()
(oc_profile / 'opencode.json').write_text(json.dumps({
    '$schema': 'https://opencode.ai/config.json', 'model': 'mock/mock-model', 'small_model': 'mock/mock-model',
    'autoupdate': False, 'share': 'disabled', 'provider': openai_mock_api.opencode_config(oc_server.server_port),
    # ASK/AUTO create marker files with `touch`: an interactive session must ask first.
    'permission': {'bash': {'*': 'allow', 'touch *': 'ask'}}}, indent=1))
checkout = top / 'checkout'; checkout.mkdir()
subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
subprocess.run(['git', '-C', str(checkout), '-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '-q', '--allow-empty', '-m', 'init'], check=True)
claude_profile = top / 'claude-profile'
claude_mock_api.profile(claude_profile, claude_server.server_port, allow=['mcp__chauffeur'], trusted=[checkout])

environment = {k: v for k, v in os.environ.items() if not k.startswith(('CHAUFFEUR_', 'OPENCODE', 'CLAUDE', 'TMUX', 'XDG_'))}
environment.update({'HOME': str(home), 'SHELL': '/bin/zsh', **{k: str(v) for k, v in xdg.items()}})
log = open(artifacts / 'runtime.private.log', 'w')
runtime = subprocess.Popen([str(options.runtime.resolve(strict=True)), '--data-dir', str(root)], stdout=log, stderr=log, env=environment)
def call(method, params=None, timeout=30):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(timeout); s.connect(str(root / 'runtime/runtime.sock'))
        b = json.dumps({'id': uid(), 'version': 1, 'method': method, 'params': params or {}}).encode()
        s.sendall(struct.pack('!I', len(b)) + b)
        d = json.loads(exact(s, struct.unpack('!I', exact(s, 4))[0]))
        assert not d.get('error'), d.get('error')
        return d.get('result')
def tmux_run(*args): return subprocess.run([tmux, '-S', str(root / 'runtime/tmux.sock'), *args], capture_output=True, text=True)
def screen(s): return tmux_run('capture-pane', '-p', '-t', s['id']).stdout
def cursor(s): return tuple(int(v) for v in tmux_run('display-message', '-p', '-t', s['id'], '#{cursor_x}|#{cursor_y}').stdout.strip().split('|'))
def classify(s):
    view = screen(s); x, y = cursor(s)
    return composer(view.split('\n'), x, y), view, x, y
def capture(s, name):
    kind, view, x, y = classify(s)
    (artifacts / f'composer-{name}.txt').write_text(f'# cursor x={x} y={y} rule={kind}\n{view}')
    return kind
def keys(s, value): tmux_run('send-keys', '-t', s['id'], '-l', '--', value); time.sleep(0.6); tmux_run('send-keys', '-t', s['id'], 'Enter')
def snapshot(): return call('snapshot')
def current(s): return next(v for v in snapshot()['sessions'] if v['id'] == s['id'])
def messages(body): return [m for m in snapshot()['messages'] if m['body'] == body]
def args_of(s): return subprocess.check_output(['/bin/ps', '-o', 'args=', '-p', str(current(s)['processID'])], text=True)
def ready(s, timeout=90):
    def probe():
        view = screen(s)
        return '╹▀' in view and ('Ask anything' in view or 'ctrl+p' in view) and 'esc interrupt' not in view
    wait(probe, timeout=timeout, label='prompt ' + s['title'])
def turn_requests(prefix): return [r for r in list(oc_requests) if r.get('tools') and oc_turn(r['messages'])[0].startswith(prefix)]

# Status transitions per session, sampled from the snapshot.
transitions = {}
sampling = threading.Event()
def sampler():
    while not sampling.is_set():
        try:
            for v in snapshot()['sessions']:
                row = (v['state'], v.get('waiting'))
                history = transitions.setdefault(v['id'], [])
                if not history or history[-1][1:] != row: history.append((round(time.monotonic(), 2), *row))
        except Exception: pass
        time.sleep(0.05)
def states(s): return [t[1] for t in transitions.get(s['id'], [])]

sessions, results, failures = [], {}, {}
def check(name, fn):
    """Runs one check; a failure is recorded and later checks still run."""
    try:
        results[name] = fn(); print(f'PASS {name}: {results[name]}', flush=True)
    except Fatal: raise
    except BaseException as error:
        failures[name] = f'{type(error).__name__}: {error}'; print(f'FAIL {name}: {failures[name]}', flush=True)
        if isinstance(error, KeyboardInterrupt): raise

try:
    wait(lambda: call('status').get('mcpEndpoint'), label='runtime')
    threading.Thread(target=sampler, daemon=True).start()
    now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    set_id, oc_preset, oc_auto_preset, claude_preset, project_id, folder_id, group_id = [uid() for _ in range(7)]
    call('savePresetSet', {'record': {'id': set_id, 'name': 'OpenCode fixture', 'agentSelection': 'custom', 'configurationDirectories': {'claude': str(claude_profile), 'opencode': str(oc_profile)}, 'revision': 1, 'archived': False}})
    call('savePreset', {'record': {'id': oc_preset, 'setID': set_id, 'name': 'OpenCode mock', 'kind': 'opencode', 'executable': options.opencode, 'configurationDirectory': str(oc_profile), 'arguments': [], 'integration': 'unverified', 'archived': False}})
    call('savePreset', {'record': {'id': oc_auto_preset, 'setID': set_id, 'name': 'OpenCode auto', 'kind': 'opencode', 'executable': options.opencode, 'configurationDirectory': str(oc_profile), 'arguments': ['--auto'], 'integration': 'unverified', 'archived': False}})
    call('savePreset', {'record': {'id': claude_preset, 'setID': set_id, 'name': 'Claude mock', 'kind': 'claude', 'executable': options.claude, 'configurationDirectory': str(claude_profile), 'arguments': [], 'integration': 'unverified', 'archived': False}})
    call('saveProject', {'record': {'id': project_id, 'name': 'OpenCode fixture', 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': 'Checkout', 'selectedPath': str(checkout), 'canonicalPath': str(checkout), 'availability': 'available', 'registered': True}], 'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
    def launch(title, preset):
        s = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset, 'folderID': folder_id, 'additionalFolderIDs': [], 'title': title, 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()}, timeout=90)
        sessions.append(s); ready(s); return s

    # ---- Launch, plugin load and conversation adoption.
    a = launch('OpenCode A', oc_preset)
    plugin = root / 'plugins/chauffeur-opencode.js'
    def launched():
        assert plugin.is_file(), plugin
        assert ' ' in str(plugin)
        env = subprocess.check_output(['/bin/ps', 'eww', '-o', 'command=', '-p', str(current(a)['processID'])], text=True)
        (artifacts / 'opencode-process.private.txt').write_text(env)
        assert 'Application%20Support' in env, 'plugin URL is percent-encoded'
        assert '"timeout":300000' in env
        assert str(home) in env and 'XDG_CONFIG_HOME=' + str(xdg['XDG_CONFIG_HOME']) in env, 'isolated XDG'
        assert current(a)['launch']['preset']['kind'] == 'opencode'
        return {'plugin': str(plugin), 'configurationDirectoryEnvironment': 'OPENCODE_CONFIG_DIR=' in env}
    check('launch', launched)
    first = capture(a, 'first-turn')

    # ---- Attention: an "ask" permission in an interactive session.
    def attention():
        keys(a, 'ASK one')
        wait(lambda: current(a)['state'] == 'needsAttention', timeout=40, label='needs attention')
        time.sleep(0.5); capture(a, 'permission-dialog')
        tmux_run('send-keys', '-t', a['id'], 'Enter')
        wait(lambda: issued_for('opencode', 'text', 'ASK one'), timeout=30, label='ASK finished')
        wait(lambda: current(a)['state'] == 'turnFinished', timeout=30, label='A turn finished')
        seen = states(a)
        i = seen.index('needsAttention')
        assert 'running' in seen[i + 1:], seen
        assert (checkout / 'ask-one.txt').exists(), 'the permitted command ran'
        return {'states': seen}
    check('attention', attention)
    def question():
        keys(a, 'QUESTION one')
        wait(lambda: current(a)['state'] == 'needsAttention', timeout=40, label='question needs attention')
        time.sleep(0.5); capture(a, 'question-dialog')
        tmux_run('send-keys', '-t', a['id'], 'Enter')
        done = wait(lambda: issued_for('opencode', 'text', 'QUESTION one'), timeout=30, label='QUESTION finished')
        wait(lambda: current(a)['state'] == 'turnFinished', timeout=30, label='A turn finished')
        seen = states(a); i = len(seen) - 1 - seen[::-1].index('needsAttention')
        assert 'running' in seen[i + 1:], seen
        assert done[-1][3] == 'QUESTION_DONE answered', done[-1][3]
        return {'answer': done[-1][3], 'states': seen[i - 1:]}
    check('questionAttention', question)
    def adoption():
        native = current(a)['nativeConversationID']
        assert native and re.fullmatch(r'ses_[A-Za-z0-9]{26}', native), native
        seen = states(a)
        assert 'running' in seen and seen[-1] == 'turnFinished', seen
        return {'nativeConversationID': native}
    check('adoption', adoption)
    original = current(a).get('nativeConversationID')
    idle = capture(a, 'idle')
    tmux_run('send-keys', '-t', a['id'], '-l', '--', 'a draft here'); time.sleep(0.8)
    draft = capture(a, 'draft')
    for _ in range(len('a draft here')): tmux_run('send-keys', '-t', a['id'], 'BSpace')
    time.sleep(0.8)

    # ---- --auto: no attention flash.
    x = launch('OpenCode S', oc_auto_preset)
    def auto():
        keys(x, 'AUTO one')
        wait(lambda: issued_for('opencode', 'text', 'AUTO one'), timeout=40, label='AUTO finished')
        wait(lambda: current(x)['state'] == 'turnFinished', timeout=30, label='S turn finished')
        assert (checkout / 'auto-one.txt').exists()
        assert 'needsAttention' not in states(x), states(x)
        return {'states': states(x)}
    check('autoNoAttention', auto)

    # ---- Inbox wait cap, in the background: S receives no mail.
    cap = {}
    def cap_probe():
        env = subprocess.check_output(['/bin/ps', 'eww', '-o', 'command=', '-p', str(current(x)['processID'])], text=True)
        token = re.search(r'CHAUFFEUR_SESSION_TOKEN=(\S+)', env).group(1)
        endpoint = call('status')['mcpEndpoint']
        body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': 'chauffeur_inbox', 'arguments': {'waitSeconds': 300}}}).encode()
        request = urllib.request.Request(endpoint, data=body, headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'})
        started = time.monotonic()
        with urllib.request.urlopen(request, timeout=400) as response: cap['body'] = response.read().decode()[:400]
        cap['elapsed'] = round(time.monotonic() - started, 1)
    cap_thread = None if options.quick else threading.Thread(target=lambda: cap.update(error=None) if cap_probe() is None else None, daemon=True)
    if cap_thread: cap_thread.start()

    # ---- Mid-turn mail: one PostToolUse reminder.
    def post_tool_use():
        keys(a, 'BUSY one')
        wait(lambda: issued_for('opencode', 'bash', 'BUSY one'), timeout=30, label='A busy'); time.sleep(1.5)
        capture(a, 'busy')
        keys(x, f'SEND {a["id"]} busy-mail')
        wait(lambda: messages('busy-mail'), timeout=30, label='S sent')
        wait(lambda: issued_for('opencode', 'chauffeur_inbox', 'BUSY one'), timeout=40, label='A read inbox')
        wait(lambda: current(a)['state'] == 'turnFinished', timeout=30, label='A idle')
        last = turn_requests('BUSY one')[-1]
        tool_outputs = [text_of(m) for m in oc_turn(last['messages'])[1] if m['role'] == 'tool']
        count = sum(o.count('Chauffeur: 1 new inbox message.') for o in tool_outputs)
        assert count == 1, tool_outputs
        return 'one reminder appended to the bash output, then chauffeur_inbox'
    check('postToolUseReminder', post_tool_use)

    # ---- Mail during the final answer: one continuation.
    def stop_continuation():
        wait(lambda: current(x)['state'] == 'turnFinished', timeout=30, label='S idle')
        keys(a, 'QUICK one')
        wait(lambda: turn_requests('QUICK one'), timeout=30, label='A answering')
        keys(x, f'SEND {a["id"]} late-mail')
        wait(lambda: messages('late-mail'), timeout=30, label='late mail')
        wait(lambda: issued_for('opencode', 'text', 'QUICK one'), timeout=30, label='QUICK answered')
        wait(lambda: issued_for('opencode', 'text', 'Chauffeur: 1 new inbox message'), timeout=40, label='continuation read inbox')
        wait(lambda: current(a)['state'] == 'turnFinished', timeout=30, label='A finished')
        time.sleep(3)
        continuations = {p for r in turn_requests('Chauffeur:') if 'QUICK one' in conversation(r['messages']) for p in [oc_turn(r['messages'])[0]]}
        assert len(continuations) == 1, continuations
        view = screen(a); assert view.count('Chauffeur: 1 new inbox message') == 1, 'typed once in the TUI'
        return {'continuation': sorted(continuations)[0][:80]}
    check('stopContinuation', stop_continuation)

    # ---- Coordinator: OpenCode coordinator, OpenCode and Claude workers.
    c = launch('OpenCode coordinator', oc_preset)
    def coordinator():
        keys(c, f'DELEGATE {oc_preset} {claude_preset} {folder_id}')
        wait(lambda: issued_for('opencode', 'text', 'DELEGATE'), timeout=60, label='coordinator delegated')
        discover = [o for r in turn_requests('DELEGATE') for o in oc_results(oc_turn(r['messages'])[1], 'chauffeur_discover')][-1]
        assert '"pluginWait":true' in discover.replace(' ', ''), discover[:600]
        assert '"waitCommand":null' in discover.replace(' ', ''), 'no shell waiter for OpenCode'
        wait(lambda: current(c)['state'] == 'turnFinished' and current(c).get('waiting') == 'workers', timeout=30, label='coordinator waiting for workers')
        assert not current(c)['unread'], 'waiting is not unread work'
        idle_requests = len([r for r in oc_requests if 'DELEGATE' in conversation(r.get('messages', []))])
        workers = wait(lambda: (lambda w: w if len(w) == 2 else None)([s for s in snapshot()['sessions'] if s.get('parentID') == c['id']]), timeout=60, label='two workers')
        sessions.extend(workers)
        kinds = sorted(w['launch']['preset']['kind'] for w in workers)
        assert kinds == ['claude', 'opencode'], kinds
        oc_worker = next(w for w in workers if w['launch']['preset']['kind'] == 'opencode')
        assert '--auto' in args_of(oc_worker), args_of(oc_worker)
        wait(lambda: len([m for m in snapshot()['messages'] if m.get('delegationID') and m['body'].startswith('worker-result')]) == 2, timeout=120, label='both results')
        wait(lambda: len(issued_for('opencode', 'wake')) >= 1, timeout=40, label='coordinator woke')
        # Between the end of the delegating turn and the first wake the model got nothing.
        wake_at = next(i for i, r in enumerate(oc_requests) if 'DELEGATE' in conversation(r.get('messages', [])) and oc_turn(r['messages'])[0].startswith('Chauffeur:'))
        between = [r for r in oc_requests[:wake_at] if 'DELEGATE' in conversation(r.get('messages', []))]
        assert len(between) == idle_requests, (len(between), idle_requests)
        wait(lambda: current(c)['state'] == 'turnFinished' and current(c).get('waiting') is None and issued_for('opencode', 'text', 'Chauffeur:') and len({i[2] for i in issued_for('opencode', 'wake')}) >= 1 and all(r in json.dumps([i[2] for i in issued_for('opencode', 'wake')]) for r in ['worker-result-oc', 'worker-result-claude']), timeout=90, label='both results woke the coordinator')
        time.sleep(3)
        wakes = sorted({i[2] for i in issued_for('opencode', 'wake')})
        per_result = {r: sum(w.count(r) for w in wakes) for r in ['worker-result-oc', 'worker-result-claude']}
        assert per_result == {'worker-result-oc': 1, 'worker-result-claude': 1}, per_result
        return {'workers': kinds, 'wakes': len(wakes), 'perResult': per_result, 'modelRequestsWhileWaiting': 0, 'coordinatorStates': states(c)}
    check('coordinator', coordinator)

    # ---- Follow-up to the idle OpenCode worker (composer rule).
    def follow_up():
        wait(lambda: issued_for('opencode', 'text', 'FOLLOWUP check'), timeout=60, label='worker ran the follow-up')
        oc_worker = next(s for s in snapshot()['sessions'] if s.get('parentID') == c['id'] and s['launch']['preset']['kind'] == 'opencode')
        wait(lambda: current(oc_worker)['state'] == 'turnFinished', timeout=30, label='worker idle after follow-up')
        worker_idle = capture(oc_worker, 'worker-idle')
        replies = max((oc_results(r['messages'], 'chauffeur_follow_up') for r in list(oc_requests) if r.get('tools')), key=len)
        attempts = [(re.search(r'"state"\s*:\s*"(\w+)"', a) or re.search(r'(.{0,80})', a)).group(1) for a in replies]
        assert attempts and attempts[-1] == 'submitted', attempts
        return {'followUpStates': attempts, 'workerIdleRule': worker_idle}
    check('followUp', follow_up)

    # ---- Composer lines vs. the rule.
    def composer_rule():
        got = {'first-turn': first, 'idle': idle, 'draft': draft, 'busy': (artifacts / 'composer-busy.txt').read_text().split('rule=')[1].split('\n')[0]}
        expected = {'first-turn': 'ready', 'idle': 'ready', 'draft': 'inputPending', 'busy': 'unrecognized'}
        assert got == expected, got
        return got
    check('composerRule', composer_rule)

    # ---- Resume.
    def resume():
        call('stop', {'sessionID': a['id'], 'force': True})
        wait(lambda: current(a)['state'] in ('exited', 'interrupted', 'failed'), timeout=30, label='A stopped')
        resumed = call('resume', {'sessionID': a['id']}, timeout=90)
        arguments = args_of(a)
        assert f'-s {original}' in arguments, arguments
        ready(a)
        keys(a, 'RESUMED one')
        done = wait(lambda: issued_for('opencode', 'text', 'RESUMED one'), timeout=40, label='resumed turn')
        wait(lambda: current(a)['state'] == 'turnFinished', timeout=30, label='resumed idle')
        assert done[-1][3].endswith('history-kept'), done[-1][3]
        assert current(a)['nativeConversationID'] == original
        return {'arguments': arguments.strip().split(' ', 1)[1], 'nativeConversationID': original}
    check('resume', resume)

    # ---- /new inside the TUI moves the session to the new conversation.
    def new_conversation():
        keys(a, '/new'); time.sleep(1.5)
        assert current(a)['nativeConversationID'] == original, 'nothing moves before the first prompt'
        keys(a, 'FRESH one')
        done = wait(lambda: issued_for('opencode', 'text', 'FRESH one'), timeout=40, label='fresh turn')
        assert done[-1][3].endswith('history-lost'), done[-1][3]
        fresh = wait(lambda: (lambda n: n if n != original else None)(current(a)['nativeConversationID']), timeout=20, label='new conversation adopted')
        assert re.fullmatch(r'ses_[A-Za-z0-9]{26}', fresh), fresh
        wait(lambda: current(a)['state'] == 'turnFinished', timeout=30, label='fresh idle')
        # Mail during the answer continues the new conversation, not the first one.
        keys(a, 'QUICK fresh')
        wait(lambda: turn_requests('QUICK fresh'), timeout=30, label='A answering in the new conversation')
        keys(x, f'SEND {a["id"]} fresh-mail')
        wait(lambda: messages('fresh-mail'), timeout=30, label='fresh mail sent')
        continued = wait(lambda: [r for r in turn_requests('Chauffeur:') if 'QUICK fresh' in conversation(r['messages'])], timeout=40, label='new conversation read its mail')
        assert 'RESUMED one' not in conversation(continued[-1]['messages']), 'mail went to the first conversation'
        wait(lambda: current(a)['state'] == 'turnFinished', timeout=30, label='fresh idle after mail')
        call('stop', {'sessionID': a['id'], 'force': True})
        wait(lambda: current(a)['state'] in ('exited', 'interrupted', 'failed'), timeout=30, label='A stopped again')
        call('resume', {'sessionID': a['id']}, timeout=90)
        arguments = args_of(a)
        assert f'-s {fresh}' in arguments, arguments
        ready(a)
        keys(a, 'REOPENED one')
        reopened = wait(lambda: issued_for('opencode', 'text', 'REOPENED one'), timeout=40, label='reopened turn')
        assert reopened[-1][3].endswith('fresh'), reopened[-1][3]
        return {'first': original, 'new': fresh, 'resumeArguments': arguments.strip().split(' ', 1)[1]}
    check('newConversation', new_conversation)

    # ---- Remote inventory kind.
    def remote_kind():
        builder = (repo / 'Sources/ChauffeurRuntimeKit/RemoteInventoryBuilder.swift').read_text()
        protocol = (repo / 'Sources/ChauffeurRemoteProtocol/RemoteModels.swift').read_text()
        assert 'case opencode' in protocol and re.search(r'case \.opencode:\s*(return )?\.opencode', builder), 'RemoteSessionKind.opencode mapping'
        return {'snapshotKind': current(a)['launch']['preset']['kind'], 'remoteKind': 'opencode (RemoteInventoryBuilder.kind)'}
    check('remoteKind', remote_kind)

    if cap_thread:
        def inbox_cap():
            cap_thread.join(timeout=320)
            assert 'elapsed' in cap, cap
            assert 230 <= cap['elapsed'] <= 262, cap
            return cap
        check('inboxWaitCap', inbox_cap)

    for s in sessions:
        try: (artifacts / f'terminal-{s["title"].replace(" ", "-")}.private.txt').write_text(screen(s))
        except Exception: pass
    results['versions'] = {s['title']: current(s)['launch']['executableVersion'] for s in sessions}
    results['failures'] = failures
    results['result'] = 'pass' if not failures else 'fail'
    (artifacts / 'summary.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))
finally:
    sampling.set()
    for s in sessions:
        try: (artifacts / f'terminal-{s["title"].replace(" ", "-")}.private.txt').write_text(screen(s))
        except Exception: pass
    (artifacts / 'opencode-requests.private.json').write_text(json.dumps(oc_requests, indent=1))
    (artifacts / 'claude-requests.private.json').write_text(json.dumps(claude_requests, indent=1))
    (artifacts / 'transitions.json').write_text(json.dumps(transitions, indent=1))
    (artifacts / 'issued.json').write_text(json.dumps(issued, indent=1))
    try: (artifacts / 'snapshot.private.json').write_text(json.dumps(snapshot(), indent=2))
    except Exception: pass
    try:
        for s in snapshot()['sessions']:
            if s['state'] not in ('exited', 'failed', 'interrupted'): call('stop', {'sessionID': s['id'], 'force': True})
    except Exception: pass
    runtime.terminate()
    try: runtime.wait(timeout=5)
    except subprocess.TimeoutExpired: runtime.kill()
    tmux_run('kill-server'); oc_server.shutdown(); claude_server.shutdown(); log.close()
    if options.keep: print('kept', top)
    else: shutil.rmtree(top, ignore_errors=True)
sys.exit(1 if failures else 0)
