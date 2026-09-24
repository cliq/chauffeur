#!/usr/bin/env python3
"""One OpenCode session through the real runtime against a real local model (not
scripted): an OpenAI-compatible server such as `mlx_lm.server`. The model is asked
to call `chauffeur_discover` (exposed as `chauffeur_chauffeur_discover`) and to run
one bash command; the smoke checks the plugin's status reports (Running → Turn
finished), the adopted `ses_…` ID, the MCP call and the command's effect.

Title generation goes to a local stub, so the model serves one request at a time.
HOME and XDG directories are throwaway; the data root contains a space.

  swift build && Prototypes/opencode_live_smoke.py [--base-url URL] [--model ID]
"""
import argparse, json, os, re, shutil, socket, struct, subprocess, sys, tempfile, threading, time, uuid
from pathlib import Path

os.umask(0o077)
repo = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(repo / 'Prototypes/inbox_hooks'))
import openai_mock_api

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--opencode', default=shutil.which('opencode'))
parser.add_argument('--runtime', type=Path, default=repo / '.build/debug/ChauffeurRuntime')
parser.add_argument('--base-url', default='http://127.0.0.1:8081/v1')
parser.add_argument('--model', default='/Users/leolobato/models/Qwen3-14B-4bit')
parser.add_argument('--timeout', type=int, default=900, help='seconds for the whole turn')
parser.add_argument('--skill-name', action='store_true', help='ask for `chauffeur_discover`, as the skills name it, instead of the exposed tool name')
parser.add_argument('--artifacts', type=Path, default=repo / '.local/opencode-live-smoke')
options = parser.parse_args()
tmux = shutil.which('tmux')
assert options.opencode and tmux
artifacts = options.artifacts.resolve(); artifacts.mkdir(parents=True, exist_ok=True)
def uid(): return str(uuid.uuid4()).upper()
def wait(probe, timeout=60, label='condition'):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            value = probe()
            if value: return value
        except (OSError, ValueError, AssertionError, KeyError, StopIteration, IndexError, TypeError): pass
        time.sleep(0.5)
    raise AssertionError('Timed out: ' + label)
def exact(s, n):
    b = bytearray()
    while len(b) < n:
        v = s.recv(n - len(b)); assert v, 'connection closed'; b.extend(v)
    return b

titles, _ = openai_mock_api.serve(lambda body: (0, [{'type': 'text', 'text': 'Live smoke'}]))
top = Path(tempfile.mkdtemp(prefix='chol-', dir='/tmp')).resolve()
root = top / 'Application Support' / 'Chauffeur'; root.mkdir(parents=True)
home = top / 'home'
xdg = {'XDG_CONFIG_HOME': home / '.config', 'XDG_DATA_HOME': home / '.local/share', 'XDG_STATE_HOME': home / '.local/state', 'XDG_CACHE_HOME': home / '.cache'}
for d in xdg.values(): d.mkdir(parents=True)
profile = xdg['XDG_CONFIG_HOME'] / 'opencode'; profile.mkdir()
(profile / 'opencode.json').write_text(json.dumps({
    '$schema': 'https://opencode.ai/config.json', 'model': 'local/' + options.model, 'small_model': 'mock/mock-model',
    'autoupdate': False, 'share': 'disabled',
    'provider': {**openai_mock_api.opencode_config(titles.server_port),
                 'local': {'npm': '@ai-sdk/openai-compatible', 'name': 'Local model', 'options': {'baseURL': options.base_url},
                           'models': {options.model: {'name': 'Local model', 'tool_call': True, 'limit': {'context': 32768, 'output': 4096}}}}}}, indent=1))
checkout = top / 'checkout'; checkout.mkdir()
subprocess.run(['git', '-C', str(checkout), 'init', '-q'], check=True)
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
def screen(s): return tmux_run('capture-pane', '-p', '-S', '-2000', '-t', s['id']).stdout
def current(s): return next(v for v in call('snapshot')['sessions'] if v['id'] == s['id'])

result, states, session = {}, [], None
started = time.monotonic()
try:
    wait(lambda: call('status').get('mcpEndpoint'), label='runtime')
    now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    set_id, preset, project_id, folder_id, group_id = [uid() for _ in range(5)]
    call('savePresetSet', {'record': {'id': set_id, 'name': 'Live', 'agentSelection': 'custom', 'configurationDirectories': {'opencode': str(profile)}, 'revision': 1, 'archived': False}})
    call('savePreset', {'record': {'id': preset, 'setID': set_id, 'name': 'OpenCode live', 'kind': 'opencode', 'executable': options.opencode, 'configurationDirectory': str(profile), 'arguments': [], 'integration': 'unverified', 'archived': False}})
    call('saveProject', {'record': {'id': project_id, 'name': 'Live', 'presetSetID': set_id, 'folders': [{'id': folder_id, 'name': 'Checkout', 'selectedPath': str(checkout), 'canonicalPath': str(checkout), 'availability': 'available', 'registered': True}], 'groups': [{'id': group_id, 'name': 'Default', 'isDefault': True, 'archived': False, 'createdAt': now, 'updatedAt': now}], 'archived': False, 'createdAt': now, 'updatedAt': now, 'lastOpenedAt': now}})
    session = call('launch', {'projectID': project_id, 'groupID': group_id, 'presetID': preset, 'folderID': folder_id, 'additionalFolderIDs': [], 'title': 'Live', 'allowSharedCheckout': True, 'coordinationEnabled': True, 'retryKey': uid()}, timeout=90)
    wait(lambda: 'Ask anything' in screen(session), timeout=90, label='prompt')
    tool_name = 'chauffeur_discover' if options.skill_name else 'chauffeur_chauffeur_discover'
    task = (f'Do exactly two things, then stop. First call the {tool_name} tool (no arguments). '
            'Then use the bash tool to run: echo "$(pwd)" > live.txt . Finally reply with the word DONE and the value of scope from the discover result. /no_think')
    tmux_run('send-keys', '-t', session['id'], '-l', '--', task); time.sleep(0.8); tmux_run('send-keys', '-t', session['id'], 'Enter')
    def sample():
        s = current(session)['state']
        if not states or states[-1] != s: states.append(s)
        return s == 'turnFinished' and 'running' in states
    wait(sample, timeout=options.timeout, label='turn finished')
    view = screen(session)
    (artifacts / 'terminal.private.txt').write_text(view)
    final = current(session)
    result = {'states': states, 'nativeConversationID': final['nativeConversationID'], 'seconds': round(time.monotonic() - started),
              # A successful MCP call shows as `⚙ chauffeur_chauffeur_discover`; a wrong name as OpenCode's
              # "unavailable tool '…'. Available tools: …" error.
              'discoverCalled': bool(re.search(r'⚙ chauffeur_chauffeur_discover', view)),
              'invalidToolCalls': sorted(set(re.findall(r"'([\w-]+)'\. Available tools", view))), 'bashRan': (checkout / 'live.txt').exists(),
              'repliedDone': 'DONE' in view.split('chauffeur_chauffeur_discover')[-1]}
    ok = bool(re.fullmatch(r'ses_[A-Za-z0-9]{26}', final['nativeConversationID'] or '')) and result['discoverCalled'] and result['bashRan']
    result['result'] = 'pass' if ok else 'fail'
except BaseException as error:
    result.update({'states': states, 'error': f'{type(error).__name__}: {error}', 'result': 'fail'})
    if session:
        try: (artifacts / 'terminal.private.txt').write_text(screen(session))
        except Exception: pass
finally:
    try:
        for s in call('snapshot')['sessions']:
            if s['state'] not in ('exited', 'failed', 'interrupted'): call('stop', {'sessionID': s['id'], 'force': True})
    except Exception: pass
    runtime.terminate()
    try: runtime.wait(timeout=5)
    except subprocess.TimeoutExpired: runtime.kill()
    tmux_run('kill-server'); titles.shutdown(); log.close()
    shutil.rmtree(top, ignore_errors=True)
    (artifacts / 'summary.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
sys.exit(0 if result.get('result') == 'pass' else 1)
